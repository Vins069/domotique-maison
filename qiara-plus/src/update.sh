#!/bin/sh
# qp-update : installation, essai, validation et retour arriere des binaires OpenQiara (Claude, 26/10/2026 ; v6 27/10 :
# pas de depot pendant un essai en cours, validation refusee si le binaire de new n'est pas celui qui tourne, use-prev idempotent).
# Usage : qp-update use-prev                 revient a la version validee precedente (prev)
#         qp-update stage FICHIER [SHA256]   depose FICHIER dans l'emplacement new et lance un essai au prochain demarrage
#         qp-update promote                  copie new dans good (l'essai est reussi)
#         qp-update rollback                 abandonne l'essai : new est ecarte, retour a good
#         qp-update seed-factory FICHIER     installe le binaire d'origine (une seule fois, par l'installation)
#         qp-update seed-good FICHIER        installe le binaire de reference courant (par l'installation)
#         qp-update status                   etat lisible (aussi ecrit dans $RUN/status-update)
QP_WHO=qp-update
QP=${QP:-/data/qp}
#@INCLUDE common.sh
MINSZ=${QP_MIN_SIZE:-1000000}
MAXSZ=${QP_MAX_SIZE:-24000000}   # un binaire non compresse (sans UPX) fait ~11 Mo
SAFETY_KB=${QP_SAFETY_KB:-4096}

die() { echo "ERREUR: $*" >&2; log "ERREUR: $*"; exit 1; }

free_kb() { # place libre en Kio ; vide si df ne sait pas repondre (le controle est alors sauté, cp echouera proprement)
  [ -n "$QP_FAKE_FREE" ] && { echo "$QP_FAKE_FREE"; return; }
  df -k "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'
}

# Le fichier est-il un executable ELF 32 bits ARM de taille plausible ?
check_elf() { # check_elf fichier
  f=$1
  [ -s "$f" ] || die "fichier vide ou absent : $f"
  sz=$(wc -c < "$f"); [ "$sz" -ge "$MINSZ" ] && [ "$sz" -le "$MAXSZ" ] || die "taille $sz hors de [$MINSZ,$MAXSZ]"
  hdr=$(od -An -tx1 -N20 "$f" | tr -d ' \n')
  case "$hdr" in
    7f454c46*) ;;
    *) die "ce n'est pas un executable ELF" ;;
  esac
  # octet 5 = classe (01 = 32 bits), octet 19 (offset 18) = machine (28 = ARM)
  [ "$(echo "$hdr" | cut -c9-10)" = 01 ] || die "ELF non 32 bits"
  [ "$(echo "$hdr" | cut -c37-38)" = 28 ] || die "ELF non ARM"
}

# Copie atomique et verifiee : fichier.part -> sync -> empreinte -> renommage.
# QP_LINK=1 : lien physique au lieu d'une copie quand source et destination sont sur la meme partition
# (binaire d'origine sur /data : aucune place consommee). La place demandee = taille du fichier + reserve
# (l'ancien fichier de l'emplacement n'est libere qu'au renommage final).
install_file() { # install_file source dossier_dest [sha_attendu]
  src=$1; dst=$2; want=$3
  mkdir -p "$dst" || die "dossier $dst impossible"
  sz=$(wc -c < "$src")
  srcsha=$(sha_of "$src")
  [ -z "$want" ] || [ "$want" = "$srcsha" ] || die "empreinte du fichier source differente de celle attendue"
  rm -f "$dst/openqiarad.part"
  linked=0
  [ -n "$QP_LINK" ] && ln "$src" "$dst/openqiarad.part" 2>/dev/null && linked=1
  if [ "$linked" = 0 ]; then
    need=$(( sz / 1024 + SAFETY_KB ))
    have=$(free_kb "$dst")
    if [ -n "$have" ]; then
      [ "$have" -ge "$need" ] || die "place insuffisante dans $dst : ${have} Kio libres, ${need} Kio necessaires"
    fi
    cp "$src" "$dst/openqiarad.part" || { rm -f "$dst/openqiarad.part"; die "copie impossible (disque plein ?)"; }
  fi
  sync
  [ "$(sha_of "$dst/openqiarad.part")" = "$srcsha" ] || { rm -f "$dst/openqiarad.part"; die "la copie n'a pas la meme empreinte que la source"; }
  chmod 755 "$dst/openqiarad.part"
  # L'emplacement devient inutilisable le temps du remplacement (pas d'empreinte), puis redevient valide d'un coup.
  rm -f "$dst/openqiarad.sha256" "$dst/BAD" "$dst/HEALTH_SEEN"
  mv -f "$dst/openqiarad.part" "$dst/openqiarad" || die "renommage impossible"
  put "$dst/openqiarad.sha256" "$srcsha  openqiarad"
  sync
  [ "$(sha_of "$dst/openqiarad")" = "$srcsha" ] || die "controle final de $dst en echec"
  echo "$srcsha"
}

# v6 : la copie de secours $OLD (lue par le lanceur quand aucun emplacement n'est utilisable, et par post_boot.sh quand
# /data/openqiarad a disparu) suit la version de reference : sans cela elle reste le binaire du 24/10 (ancien, compresse UPX).
# Copie verifiee, empreinte a cote ; un echec (place, carte) n'empeche pas l'operation principale.
refresh_old() { # refresh_old source
  [ -n "$QP_NO_OLD" ] && return 0
  _os=$(sha_of "$1"); [ -n "$_os" ] || return 0
  [ "$(sha_of "$OLD")" = "$_os" ] && return 0
  rm -f "$OLD.part"
  # v9 : l'ancienne empreinte est retiree avant le renommage ; une coupure entre les deux laisse une copie sans empreinte
  # (acceptee par le lanceur, comportement v5) et non une copie refusee pour empreinte differente.
  if cp "$1" "$OLD.part" 2>/dev/null && sync && [ "$(sha_of "$OLD.part")" = "$_os" ] && chmod 755 "$OLD.part" && rm -f "$OLD.sha256" && mv -f "$OLD.part" "$OLD"; then
    put "$OLD.sha256" "$_os  openqiarad.old"; sync; log "copie de secours $OLD mise a jour ($(echo "$_os" | cut -c1-12))"
  else
    rm -f "$OLD.part"; log "copie de secours $OLD non mise a jour (place ou carte) : l'ancienne reste en service"
  fi
  return 0
}

cmd=$1; shift
case "$cmd" in
  stage)
    f=$1; want=$2
    [ -n "$f" ] || die "stage : fichier manquant"
    check_elf "$f"
    # v6 : pendant un essai dont l'application tourne, remplacer new ferait valider (promote) un binaire qui n'a jamais tourne
    if [ -e "$ST/trial" ] && [ "$(get "$ST/running_slot" none)" = new ] && live_child && [ -z "$QP_FORCE" ]; then
      die "un essai est en cours (new tourne, pid $CH) : rollback ou promote d'abord"
    fi
    sha=$(install_file "$f" "$(sd new)" "$want") || exit 1
    put "$ST/new_starts" 0; put "$ST/fails" 0; put "$ST/trial" "$(now) $sha"
    put "$ST/active" new
    result "essai en cours : $(echo "$sha" | cut -c1-12)"
    log "nouveau binaire depose dans new ($(echo "$sha" | cut -c1-12)), essai au prochain demarrage"
    sync    # v4.1 : l'etat de l'essai (active, trial) doit etre sur la carte avant la relance
    echo "OK new=$sha"
    ;;
  promote)
    [ -s "$(sd new)/openqiarad" ] || die "emplacement new vide"
    slot_valid new || die "emplacement new invalide"
    run=$(get "$ST/running_slot" none)
    if { [ "$run" != new ] || ! live_child; } && [ "$1" != --force ]; then die "new ne tourne pas (dernier lance : $run)"; fi
    # v6 : le binaire valide doit etre celui qui a fait l'essai : meme empreinte que celle notee au depot (marqueur "date sha"),
    # et, si new tourne, un executable toujours present sur la carte (sinon /proc/pid/exe se termine par « (deleted) »)
    _tw=; _ts=; [ -s "$ST/trial" ] && read -r _tw _ts < "$ST/trial"
    [ -z "$_ts" ] || [ "$_ts" = "$(sha_of "$(sd new)/openqiarad")" ] || die "new n'est plus le binaire depose pour l'essai ($(echo "$_ts" | cut -c1-12) attendu) : pas de validation"
    if [ "$run" = new ] && live_child; then case "$(readlink /proc/$CH/exe 2>/dev/null)" in *" (deleted)") die "le binaire qui tourne n'est plus celui de new (remplace sous l'application) : pas de validation";; esac; fi
    # la version validee jusqu'ici est gardee en prev : retour possible meme apres validation
    if slot_valid good && [ "$(sha_of "$(sd good)/openqiarad")" != "$(sha_of "$(sd new)/openqiarad")" ]; then
      install_file "$(sd good)/openqiarad" "$(sd prev)" >/dev/null || log "copie de good vers prev impossible (on continue)"
    fi
    sha=$(install_file "$(sd new)/openqiarad" "$(sd good)") || exit 1
    put "$ST/active" good; rm -f "$ST/trial"; put "$ST/new_starts" 0; put "$ST/fails" 0
    result "ok: $(echo "$sha" | cut -c1-12) valide"
    log "essai reussi : new promu en good ($(echo "$sha" | cut -c1-12))"
    sync
    refresh_old "$(sd good)/openqiarad"
    echo "OK good=$sha"
    ;;
  rollback)
    # sans essai en cours, rien a annuler (un appui tardif apres une validation ne doit pas ecarter la bonne version)
    if [ ! -e "$ST/trial" ] && [ -z "$QP_FORCE" ]; then
      result "rien a annuler : aucun essai en cours"; log "retour arriere demande sans essai en cours : ignore"; echo "OK (aucun essai)"; exit 0
    fi
    mark_bad new
    put "$ST/active" good; rm -f "$ST/trial"; put "$ST/new_starts" 0; put "$ST/fails" 0
    result "annule: retour a good${1:+ ($1)}"
    log "retour arriere : new ecarte, retour a good${1:+ ($1)}"
    sync
    if [ "$(get "$ST/running_slot" none)" = new ]; then
      if live_child; then
        true 2>/dev/null > "$ST/expected_stop"; kill "$CH" 2>/dev/null && echo "binaire new arrete, le lanceur relance good"
      fi
    fi
    echo "OK"
    ;;
  use-prev)
    slot_valid prev || die "emplacement prev absent ou invalide"
    # v6 : deja sur prev et prev tourne : rien a faire (un ordre repete ne relance pas l'application)
    if [ "$(get "$ST/active" good)" = prev ] && [ "$(get "$ST/running_slot" none)" = prev ] && live_child; then
      log "retour a prev demande : deja en cours (pid $CH), rien fait"; echo "OK active=prev (deja)"; exit 0
    fi
    put "$ST/active" prev; rm -f "$ST/trial"
    result "retour a la version precedente (prev)"
    log "retour demande a la version precedente (prev)"
    sync
    if live_child; then true 2>/dev/null > "$ST/expected_stop"; kill "$CH" 2>/dev/null; fi
    echo "OK active=prev"
    ;;
  seed-factory|seed-good)
    f=$1; [ -n "$f" ] || die "$cmd : fichier manquant"
    check_elf "$f"
    slot=${cmd#seed-}
    if [ "$slot" = factory ]; then sha=$(QP_LINK=1 install_file "$f" "$(sd $slot)" "$2") || exit 1
    else sha=$(install_file "$f" "$(sd $slot)" "$2") || exit 1; fi
    [ "$slot" = good ] && [ ! -s "$ST/active" ] && put "$ST/active" good
    log "$slot installe ($(echo "$sha" | cut -c1-12))"
    [ "$slot" = good ] && refresh_old "$(sd good)/openqiarad"
    echo "OK $slot=$sha"
    ;;
  status)
    {
      echo "active=$(get "$ST/active" good)"
      r=$(get "$ST/running_slot" none); live_child || r="aucun (dernier : $r)"
      echo "running=$r"
      echo "trial=$([ -e "$ST/trial" ] && echo 1 || echo 0)"
      echo "fails=$(get "$ST/fails" 0)"
      echo "new_starts=$(get "$ST/new_starts" 0)"
      for s in factory prev good new; do
        d=$(sd $s)
        v=none; [ -s "$d/openqiarad" ] && v=$(sha_of "$d/openqiarad" | cut -c1-12)
        b=0; slot_bad $s && b=1
        echo "slot_$s=$v bad=$b valid=$(slot_valid $s && echo 1 || echo 0)"
      done
      last_result; echo "last_result=$_lr"
      echo "free_data_kb=$(free_kb "$QP")"
      echo "free_bulk_kb=$(free_kb "$BULK")"
    } | tee "$RUN/status-update"
    ;;
  *) echo "usage: qp-update stage|promote|rollback|use-prev|seed-factory|seed-good|status" >&2; exit 2 ;;
esac
