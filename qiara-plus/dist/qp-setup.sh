#!/bin/sh
# qp-setup : installation, essai a blanc et retrait de « QIARA Plus v10 » sur la camera (distribution OpenQIARA Claude V15).
# Ce fichier est autonome : les trois outils (qp-launch, qp-guard, qp-update) sont integres a la fin, avec leurs empreintes.
# Usage : sh qp-setup.sh selftest          essai a blanc en memoire vive (rien n'est ecrit sur la carte)
#         sh qp-setup.sh preflight         controles en lecture seule, annonce ce qui serait ecrit
#         sh qp-setup.sh install --yes     installation (ecrit sur /data et /media), controle, retour arriere automatique en cas d'echec
#         sh qp-setup.sh uninstall --yes   retour a l'etat d'origine
#         sh qp-setup.sh status            etat
SELF=$0
DATA=${QP_DATA:-/data}; MEDIA=${QP_MEDIA:-/media}
QP=$DATA/qp; BULK=$MEDIA/qp; RUN=${QP_RUN:-/tmp/qp}; ST=$QP/state
APP=$DATA/openqiarad; OLD=$MEDIA/openqiarad.old
POST=$DATA/post_boot.sh
LOG=$DATA/openqiarad.log
MARK_B='# >>> qiara-plus (ne pas modifier ce bloc) >>>'
MARK_E='# <<< qiara-plus <<<'
TOOLS="qp-launch qp-guard qp-update"
VERIFY_SEC=${QP_VERIFY_SEC:-150}
PORT=${QP_PORT:-80}
STABLE_VERIFY=${QP_VERIFY_STABLE:-60}

say()  { echo "$*"; }
slog() { echo "[qp-setup] $(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$LOG" 2>/dev/null; }
die()  { echo "ERREUR: $*" >&2; slog "ERREUR: $*"; exit 1; }
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }
is_elf_arm() { [ "$(od -An -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n' | cut -c1-8)" = 7f454c46 ] && [ "$(od -An -tx1 -N20 "$1" | tr -d ' \n' | cut -c37-38)" = 28 ]; }

payload() { # payload nom sortie : extrait et decode un outil, controle l'empreinte integree
  want=$(sed -n "s/^@@FILE $1 //p" "$SELF" | head -n1)
  sed -n '/^__PAYLOAD__$/,$p' "$SELF" | awk -v n="$1" '/^@@FILE /{on=($2==n);next} on && !/^__PAYLOAD__$/' | base64 -d > "$2" 2>/dev/null || return 1
  [ "$(sha_of "$2")" = "$want" ] || return 1
}

app_pid() { # premier processus nomme openqiarad (lecture de /proc, sans dependre de pidof)
  for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = openqiarad ] && { echo "${p#/proc/}"; return 0; }; done; return 1; }
parent_is_bootsh() { # le processus pid est-il lance par la boucle de boot.sh ?
  pp=$(awk '/^PPid:/{print $2}' /proc/$1/status 2>/dev/null)
  [ -n "$pp" ] && tr '\0' ' ' < /proc/$pp/cmdline 2>/dev/null | grep -q boot.sh
}

# ---------------------------------------------------------------- essai a blanc en memoire vive
do_selftest() {
  say "== essai a blanc en memoire vive (aucune ecriture sur la carte) =="
  W=/tmp/qp-selftest.$$; rm -rf "$W"; mkdir -p "$W/qp" "$W/bulk" "$W/run" "$W/tools"
  for t in $TOOLS; do payload $t "$W/tools/$t" || { rm -rf "$W"; die "integrite de $t en echec"; }; sh -n "$W/tools/$t" || { rm -rf "$W"; die "syntaxe de $t en echec"; }; done
  say "  ok   : integrite et syntaxe des trois outils"
  # un faux binaire ELF n'est pas necessaire : on verifie le lanceur avec un script
  mkdir -p "$W/bulk/slots/good" "$W/qp/slots/factory" "$W/qp/state"
  printf '#!/bin/sh\necho "args=$*" > '"$W"'/args\nsleep 3\n' > "$W/qp/slots/factory/openqiarad"; chmod 755 "$W/qp/slots/factory/openqiarad"
  sha_of "$W/qp/slots/factory/openqiarad" > "$W/qp/slots/factory/openqiarad.sha256"
  QP="$W/qp" QP_BULK="$W/bulk" QP_RUN="$W/run" QP_LOG="$W/log" QP_STABLE_SEC=1 QP_EXEC_SH=1 sh "$W/tools/qp-launch" -web :80 -log /x
  grep -q "demarrage de factory" "$W/log" && grep -q -- "-web :80 -log /x" "$W/args" && say "  ok   : lanceur (choix de l'emplacement, arguments, surveillance)" || { rm -rf "$W"; die "essai du lanceur en echec"; }
  # surveillant : un passage, sans aucune action sur le systeme
  printf 'PASSIVE=1\nENABLE_WIFI_ACTIONS=0\nENABLE_REBOOT=0\nGATEWAY=127.0.0.1\n' > "$W/qp/guard.conf"
  printf '#!/bin/sh\nexit 0\n' > "$W/dropbear"; chmod 755 "$W/dropbear"
  QP="$W/qp" QP_BULK="$W/bulk" QP_RUN="$W/run" QP_LOG="$W/log" QP_ONCE=1 QP_TICK=1 QP_DROPBEAR="$W/dropbear" QP_LAUNCHER=/bin/true sh "$W/tools/qp-guard" 
  [ -s "$W/run/guard-status" ] && say "  ok   : surveillant (un passage, mode passif, sans action)" && grep -E '^(net_ok|mem_avail_kb|ssh22|ssh2222|video_iv|video_bitrate|video_gop_denum|video_shim|video_codec)=' "$W/run/guard-status" | sed 's/^/         /'
  grep "passif" "$W/log" | sed 's/^/         aurait fait : /'  || { rm -rf "$W"; die "essai du surveillant en echec"; }
  # outil de mise a jour : etat
  QP="$W/qp" QP_BULK="$W/bulk" QP_RUN="$W/run" QP_LOG="$W/log" sh "$W/tools/qp-update" status >/dev/null && say "  ok   : outil de mise a jour (etat)"
  rm -rf "$W"
  say "== essai a blanc reussi =="
}

# ---------------------------------------------------------------- controles en lecture seule
do_preflight() {
  say "== controles (lecture seule) =="; bad=0
  if [ -z "$QP_TEST" ]; then
    [ "$(uname -m)" = armv7l ] && say "  ok   : processeur armv7l" || { say "  KO   : processeur $(uname -m)"; bad=1; }
    mount | grep -q " $DATA " && say "  ok   : $DATA monte" || { say "  KO   : $DATA non monte"; bad=1; }
  fi
  d=$(free_kb "$DATA"); m=$(free_kb "$MEDIA")
  [ -n "$QP_TEST" ] && [ -z "$d" ] && d=99999 && say "  info : place sur $DATA inconnue (banc d'essai)"
  [ -n "$QP_TEST" ] && [ -z "$m" ] && m=99999 && say "  info : place sur $MEDIA inconnue (banc d'essai)"
  # /data : outils (~0,2 Mio) + reserve de 4 Mio (le binaire d'origine y est un lien physique : aucune place)
  # /media : copie du binaire de reference + reserve, puis deux fois le futur binaire (depot + emplacement new)
  az=$(( $(wc -c < "$APP" 2>/dev/null || echo 0) / 1024 ))
  needd=4600; needm=$(( az + 4096 + 2 * 14000 ))
  [ "${d:-0}" -ge "$needd" ] && say "  ok   : $DATA : ${d} Kio libres ($needd necessaires)" || { say "  KO   : $DATA : ${d:-?} Kio libres ($needd necessaires)"; bad=1; }
  [ "${m:-0}" -ge "$needm" ] && say "  ok   : $MEDIA : ${m} Kio libres ($needm necessaires)" || { say "  KO   : $MEDIA : ${m:-?} Kio libres ($needm necessaires)"; bad=1; }
  [ -s "$APP" ] && is_elf_arm "$APP" && say "  ok   : $APP est un executable ARM ($(wc -c < "$APP") octets, $(sha_of "$APP" | cut -c1-12))" || { [ -s "$APP" ] && head -c2 "$APP" | grep -q '#!' && say "  ok   : $APP est deja le lanceur Qiara Plus" || { say "  KO   : $APP illisible"; bad=1; }; }
  [ -s "$OLD" ] && is_elf_arm "$OLD" && say "  ok   : $OLD present ($(wc -c < "$OLD") octets, $(sha_of "$OLD" | cut -c1-12)) : repli ultime du lanceur" || say "  info : $OLD absent (repli ultime indisponible, sans gravite)"
  [ -f "$POST" ] && say "  ok   : $POST present" || say "  info : $POST absent : il sera cree (boot.sh l'execute a la fin du demarrage)"
  p=$(app_pid)
  if [ -n "$p" ] && { [ -n "$QP_TEST" ] || parent_is_bootsh "$p"; }; then say "  ok   : OpenQiara (pid $p) est relance par la boucle de boot.sh"
  elif [ -n "$p" ] && [ -f "$QP/qp-guard" ]; then say "  ok   : OpenQiara (pid $p) tourne (deja installe ?)"
  else say "  KO   : OpenQiara introuvable ou pas relance par boot.sh"; bad=1; fi
  [ -c /dev/watchdog ] && say "  info : /dev/watchdog present (non utilise : le microcontroleur radio a deja un chien de garde, nourri par OpenQiara)"
  say "== ecriture prevue : $QP (outils, etat, binaire en service en lien physique = emplacement factory), $BULK (copie good), remplacement atomique de $APP par le lanceur, un bloc ajoute a $POST (copie .avant-qp conservee) =="
  [ "$bad" = 0 ] || return 1
  say "== controles reussis =="
}

# ---------------------------------------------------------------- retrait
strip_post() { # retire le bloc de post_boot.sh (atomique)
  [ -f "$POST" ] || return 0
  grep -q "$MARK_B" "$POST" || return 0
  awk -v b="$MARK_B" -v e="$MARK_E" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$POST" > "$POST.qp.tmp" && sh -n "$POST.qp.tmp" && mv -f "$POST.qp.tmp" "$POST"
}
is_launcher() { [ "$(head -c 2 "$APP" 2>/dev/null)" = '#!' ]; }
valid_bin() { # binaire ELF ARM dont l'empreinte enregistree (si presente) est conforme
  [ -s "$1" ] && is_elf_arm "$1" || return 1
  [ -s "$1.sha256" ] || return 0
  read -r w _x < "$1.sha256"; [ "$w" = "$(sha_of "$1")" ]
}
do_uninstall() {
  say "== retrait de Qiara Plus =="; slog "retrait demande"
  # 1. binaire reel a la place du lanceur (version en service de preference, puis good, factory, origine)
  if is_launcher; then
    src=; rsl=$(head -n1 "$ST/running_slot" 2>/dev/null)
    case "$rsl" in good|new|prev) first=$BULK/slots/$rsl/openqiarad;; factory) first=$QP/slots/factory/openqiarad;; *) first=;; esac
    for c in $first "$BULK/slots/good/openqiarad" "$QP/slots/factory/openqiarad" "$BULK/slots/prev/openqiarad" "$OLD"; do
      valid_bin "$c" && { src=$c; break; }
    done
    [ -n "$src" ] || die "aucun binaire de remplacement valide : lanceur laisse en place (rien n'a ete modifie)"
    cp "$src" "$APP.qp.tmp" && chmod 755 "$APP.qp.tmp" && [ "$(sha_of "$src")" = "$(sha_of "$APP.qp.tmp")" ] && sync && mv -f "$APP.qp.tmp" "$APP" && sync || { rm -f "$APP.qp.tmp"; die "remplacement de $APP en echec (lanceur laisse en place)"; }
    say "  ok   : $APP = binaire reel ($(sha_of "$APP" | cut -c1-12), depuis $src)"
  fi
  # 2. bloc de post_boot.sh
  strip_post && say "  ok   : bloc retire de post_boot.sh"
  # 3. arret du surveillant (le lanceur n'existe plus : personne ne le relancera), puis relance de l'application
  gp=$(head -n1 "$RUN/guard.lock/pid" 2>/dev/null); [ -n "$gp" ] && kill "$gp" 2>/dev/null
  sleep 1
  p=$(app_pid); [ -n "$p" ] && kill "$p" 2>/dev/null
  say "  ok   : surveillant arrete, OpenQiara relance par boot.sh dans ~10 s"
  # 4. fichiers de Qiara Plus : retires une fois le binaire reel en place (le journal reste dans $LOG)
  if ! is_launcher && [ -s "$APP" ]; then
    rm -rf "$QP" "$BULK" "$RUN" 2>/dev/null; sync
    say "  ok   : $QP, $BULK et $RUN retires"
  fi
  slog "retrait termine"
}

# ---------------------------------------------------------------- installation
LOCKI=/tmp/qp-install.lock
abort_install() { # echec avant la bascule : on retire ce qui a ete cree pour une premiere installation
  [ "$FRESH" = 1 ] && ! is_launcher && { rm -rf "$QP" "$BULK"; sync; say "  ..   : fichiers partiels retires (premiere installation)"; }
  rm -rf "$QP/stage" "$LOCKI"; die "$1"
}
do_install() {
  [ "$1" = --yes ] || die "ajouter --yes pour confirmer l'ecriture"
  mkdir "$LOCKI" 2>/dev/null || die "une installation est deja en cours ($LOCKI)"
  trap 'rm -rf "$LOCKI"' EXIT
  do_preflight || { rm -rf "$LOCKI"; die "controles en echec, rien n'a ete ecrit"; }
  do_selftest  || { rm -rf "$LOCKI"; die "essai a blanc en echec, rien n'a ete ecrit"; }
  slog "installation demandee"
  FRESH=1; is_launcher && FRESH=0
  [ "$FRESH" = 0 ] && say "(deja installe : mise a jour des outils)"
  mkdir -p "$QP/slots/factory" "$QP/state" "$BULK/slots/good" "$BULK/slots/new" "$QP/stage" || abort_install "creation des dossiers impossible"
  # 1. outils (copies verifiees)
  for t in $TOOLS; do
    payload $t "$QP/stage/$t" || abort_install "extraction de $t en echec"
    sh -n "$QP/stage/$t" || abort_install "syntaxe de $t en echec"
  done
  for t in qp-guard qp-update; do chmod 755 "$QP/stage/$t"; mv -f "$QP/stage/$t" "$QP/$t" || abort_install "installation de $t impossible"; done
  say "  ok   : qp-guard et qp-update installes"
  # 2. emplacements d'apres l'outil de mise a jour (controles ELF, place, empreintes)
  # factory = le binaire en service avant Qiara Plus (version eprouvee), en lien physique sur /data ; good = sa copie sur /media.
  # Reinstallation : factory et good existants sont conserves.
  if [ "$FRESH" = 1 ]; then
    is_elf_arm "$APP" || abort_install "$APP n'est pas un executable ARM"
    QP="$QP" QP_BULK="$BULK" QP_RUN="$RUN" QP_OLD="$OLD" sh "$QP/qp-update" seed-factory "$APP" >/dev/null || abort_install "binaire d'origine non installe"
    QP="$QP" QP_BULK="$BULK" QP_RUN="$RUN" QP_OLD="$OLD" sh "$QP/qp-update" seed-good "$APP"  >/dev/null || abort_install "binaire de reference non installe"
  fi
  say "  ok   : factory = $(sha_of "$QP/slots/factory/openqiarad" | cut -c1-12), good = $(sha_of "$BULK/slots/good/openqiarad" | cut -c1-12)"
  # reglages memoire de l'execution Go, lus par le lanceur (liste blanche) ; effet sur toutes les versions d'OpenQiara
  [ -f "$QP/app.env" ] || printf 'GOGC=75\nGOMEMLIMIT=32MiB\n' > "$QP/app.env"
  [ -f "$QP/guard.conf" ] || printf '# Reglages du surveillant (voir docs).\nENABLE_WIFI_ACTIONS=1\nENABLE_REBOOT=1\nSSH_SECOURS_PORT=0\n' > "$QP/guard.conf"
  # 3. bloc de post_boot.sh (copie de securite, ecriture atomique)
  if [ ! -f "$POST" ]; then
    printf '%s\n' "# /data/post_boot.sh : reglages locaux, execute par boot.sh a la fin du demarrage (sortie dans /data/post_boot.log)." > "$POST.qp.tmp" && mv -f "$POST.qp.tmp" "$POST" || abort_install "creation de post_boot.sh impossible"
    say "  ok   : $POST cree"
  fi
  if ! grep -q "$MARK_B" "$POST"; then
    cp -p "$POST" "$POST.avant-qp-$(date +%Y-%m-%d)" || abort_install "copie de securite de post_boot.sh impossible"
    # bloc place en tete (apres une eventuelle ligne #!) : un « exit » plus bas dans le fichier ne l'empeche pas de s'executer
    { if head -n 1 "$POST" | grep -q '^#!'; then head -n 1 "$POST"; fi
      printf '%s\n%s\n%s\n\n' "$MARK_B" "[ -f $QP/qp-guard ] && ( nohup sh $QP/qp-guard >/dev/null 2>&1 & )" "$MARK_E"
      if head -n 1 "$POST" | grep -q '^#!'; then tail -n +2 "$POST"; else cat "$POST"; fi; } > "$POST.qp.tmp" || abort_install "ecriture de post_boot.sh impossible"
    sh -n "$POST.qp.tmp" || { rm -f "$POST.qp.tmp"; abort_install "post_boot.sh modifie invalide, abandon"; }
    mv -f "$POST.qp.tmp" "$POST"
    say "  ok   : post_boot.sh complete (copie .avant-qp conservee)"
  fi
  # 4. bascule : le lanceur remplace le binaire (ou l'ancien lanceur) d'un seul renommage atomique ;
  #    l'application en cours n'est pas touchee (le lanceur n'est lu qu'au lancement suivant)
  if ! is_launcher || [ "$(sha_of "$APP")" != "$(sha_of "$QP/stage/qp-launch")" ]; then
    mv -f "$QP/stage/qp-launch" "$APP.qp.tmp" 2>/dev/null || cp "$QP/stage/qp-launch" "$APP.qp.tmp" || { strip_post; abort_install "copie du lanceur impossible"; }
    chmod 755 "$APP.qp.tmp"; sync
    mv -f "$APP.qp.tmp" "$APP" || { rm -f "$APP.qp.tmp"; strip_post; abort_install "bascule impossible"; }
    sync
    say "  ok   : lanceur en place sous $APP"
  fi
  cp -f "$APP" "$QP/qp-launch"
  rm -rf "$QP/stage"
  # 5. mise en route : (ancien surveillant arrete) nouveau surveillant, puis relance de l'application a travers le lanceur
  gp=$(head -n1 "$RUN/guard.lock/pid" 2>/dev/null)
  if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then kill "$gp" 2>/dev/null; i=0; while [ $i -lt 10 ] && kill -0 "$gp" 2>/dev/null; do sleep 1; i=$((i+1)); done; fi
  ( nohup sh "$QP/qp-guard" >/dev/null 2>&1 & )
  sleep 2
  true 2>/dev/null > "$ST/expected_stop"; p=$(app_pid); [ -n "$p" ] && kill "$p" 2>/dev/null
  say "  ..   : OpenQiara relance par le lanceur (attente jusqu'a ${VERIFY_SEC} s)"
  # 6. controle ; en cas d'echec, retour arriere automatique
  i=0; okk=0
  while [ $i -lt "$VERIFY_SEC" ]; do
    sleep 5; i=$((i+5))
    rs=$(head -n1 "$ST/running_slot" 2>/dev/null); c=$(head -n1 "$ST/child" 2>/dev/null)
    if [ -n "$rs" ] && [ "$rs" != media-old ] && [ -n "$c" ] && kill -0 "$c" 2>/dev/null && netstat -tln 2>/dev/null | grep -q ":$PORT "; then
      rstart=$(head -n1 "$ST/run_up" 2>/dev/null); read -r upn _r < /proc/uptime
      [ $(( ${upn%%.*} - ${rstart:-0} )) -ge "$STABLE_VERIFY" ] && { okk=1; break; }
    fi
  done
  if [ "$okk" = 1 ]; then
    slog "installation terminee"; say "== installation reussie : $rs tourne depuis plus de ${STABLE_VERIFY} s a travers le lanceur, port $PORT ouvert =="
  else
    say "== controle en echec : retour arriere automatique =="; slog "controle en echec, retour arriere"
    do_uninstall; exit 1
  fi
}

do_status() {
  say "install: $( is_launcher && [ -f "$QP/qp-guard" ] && echo oui || echo non )  lanceur: $( is_launcher && echo oui || echo non )  bloc post_boot: $( grep -q "$MARK_B" "$POST" 2>/dev/null && echo oui || echo non )"
  [ -f "$QP/qp-update" ] && QP="$QP" QP_BULK="$BULK" QP_RUN="$RUN" QP_OLD="$OLD" sh "$QP/qp-update" status
  [ -s "$RUN/guard-status" ] && cat "$RUN/guard-status"
}

case "$1" in
  selftest)  do_selftest ;;
  preflight) do_preflight ;;
  install)   do_install "$2" ;;
  uninstall) [ "$2" = --yes ] || die "ajouter --yes"; do_uninstall ;;
  status)    do_status ;;
  *) echo "usage: sh qp-setup.sh selftest|preflight|install --yes|uninstall --yes|status" >&2; exit 2 ;;
esac
exit 0
__PAYLOAD__
@@FILE qp-launch 1701c45b371b13c664fd9b66962b49306b806b96f82df1d6961489a7a7afa68d
IyEvYmluL3NoCiMgTGFuY2V1ciBkJ09wZW5RaWFyYSBhIHRyb2lzIGVtcGxhY2VtZW50cyAoQ2xh
dWRlLCAyNi8xMC8yMDI2LCB2MiA7IHY2IDI3LzEwIDogbnVtZXJvIGRlIGRlbWFycmFnZSwgYXBw
LmVudiB2ZXJpZmllLAojIGZhY3RvcnkgcmVsYW5jZSBzYW5zIGFwcC5lbnYgYXByZXMgTUFYRkFJ
TCBhcnJldHMgcmFwaWRlcywgZW1wcmVpbnRlIGRlIGwnZXNzYWkgbm90ZWUgZGFucyBsZSBtYXJx
dWV1cikuCiMgSW5zdGFsbGUgc291cyAvZGF0YS9vcGVucWlhcmFkIDogbGEgYm91Y2xlIGRlIGJv
b3Quc2ggbGUgcmVsYW5jZSBjb21tZSBlbGxlIHJlbGFuY2FpdCBsZSBiaW5haXJlLgojIElsIGZh
aXQgbGUgYmlsYW4gZHUgbGFuY2VtZW50IHByZWNlZGVudCwgY2hvaXNpdCBsZSBiaW5haXJlIChu
ZXcsIGdvb2Qgb3UgZmFjdG9yeSksIHB1aXMgc2UgUkVNUExBQ0UgcGFyIGx1aSAoZXhlYykgOgoj
IGF1Y3VuIHByb2Nlc3N1cyBzdXBwbGVtZW50YWlyZSBuZSByZXN0ZSBlbiBtZW1vaXJlLCBsZXMg
c2lnbmF1eCB2b250IGRpcmVjdGVtZW50IGEgbCdhcHBsaWNhdGlvbi4KIyBUcm9pcyBhcnJldHMg
cmFwaWRlcyBkZSBzdWl0ZSAoPCBRUF9TVEFCTEVfU0VDLCBtZW1lIGRlbWFycmFnZSkgbWFycXVl
bnQgbCdlbXBsYWNlbWVudCBCQUQgZXQgZm9udCBwYXNzZXIgYXUgc3VpdmFudC4KIyBVbiBlc3Nh
aSAobmV3KSBlc3QgYXVzc2kgZWNhcnRlIHMnaWwgYSBldGUgbGFuY2UgcGx1cyBkZSBRUF9NQVhT
VEFSVCBmb2lzIHNhbnMgZXRyZSB2YWxpZGUgKGJvdWNsZSBkZSByZWRlbWFycmFnZXMpLgpRUF9X
SE89cXAtbGF1bmNoClFQPSR7UVA6LS9kYXRhL3FwfQojIGNvbW1vbi5zaCAtIGZvbmN0aW9ucyBj
b21tdW5lcyBkZSDCqyBRaWFyYSBQbHVzIMK7IChDbGF1ZGUsIDI2LzEwLzIwMjYsIHYyIDogZWNv
bm9tZSBlbiBtZW1vaXJlIGV0IGVuIHByb2Nlc3N1cyA7CiMgdjYgMjcvMTAvMjAyNiA6IGFnZXMg
bWVzdXJlcyBzdXIgbCd1cHRpbWUgZXQgbGUgbnVtZXJvIGRlIGRlbWFycmFnZSwgamFtYWlzIHN1
ciBsYSBzZXVsZSBob3Jsb2dlIG11cmFsZSkKIyBTaGVsbCA6IGJ1c3lib3ggYXNoIGRlIGxhIGNh
bWVyYS4gUmllbiBpY2kgbmUgZG9pdCBzdXBwb3NlciBiYXNoLgojIExlcyBkdXJlZXMgc2UgbWVz
dXJlbnQgc3VyIC9wcm9jL3VwdGltZSAobW9ub3RvbmUpIDogbCdob3Jsb2dlIG11cmFsZSBkZW1h
cnJlIGVuIDE5NzAgZXQgc2F1dGUgYXUgcmVnbGFnZSBOVFAuClFQPSR7UVA6LS9kYXRhL3FwfSAg
ICAgICAgICAgICAgICAgIyBwZXRpdCA6IGV0YXQsIGJpbmFpcmUgZCdvcmlnaW5lIChjYXJ0ZSAv
ZGF0YSwgMjAgTWlvKQpCVUxLPSR7UVBfQlVMSzotL21lZGlhL3FwfSAgICAgICAgICMgZ3JvcyA6
IGVtcGxhY2VtZW50cyBnb29kIGV0IG5ldyAoY2FydGUgL21lZGlhLCAyLDggR28pClJVTj0ke1FQ
X1JVTjotL3RtcC9xcH0gICAgICAgICAgICAgIyBtZW1vaXJlIHZpdmUgOiBzYW50ZSwgb3JkcmVz
LCBldGF0IGRlcyBlc3NhaXMKU1Q9JFFQL3N0YXRlCkxPRz0ke1FQX0xPRzotL2RhdGEvb3BlbnFp
YXJhZC5sb2d9Ck9MRD0ke1FQX09MRDotL21lZGlhL29wZW5xaWFyYWQub2xkfSAgICMgcmVwbGkg
dWx0aW1lIGR1IGxhbmNldXIgKGV0IGRlIHBvc3RfYm9vdC5zaCBzaSAvZGF0YS9vcGVucWlhcmFk
IGRpc3BhcmFpdCkgOyB2NiA6IHJhZnJhaWNoaSBwYXIgcHJvbW90ZS9zZWVkLWdvb2QsIGVtcHJl
aW50ZSBhIGNvdGUKWyAtZCAiJFNUIiBdICYmIFsgLWQgIiRSVU4iIF0gfHwgbWtkaXIgLXAgIiRT
VCIgIiRSVU4iIDI+L2Rldi9udWxsCgp0cygpIHsgZGF0ZSAnKyVZLSVtLSVkVCVIOiVNOiVTJzsg
fQpub3coKSB7IGRhdGUgKyVzOyB9CmxvZygpIHsgZWNobyAiWyR7UVBfV0hPOi1xcH1dICQodHMp
ICQqIiA+PiAiJExPRyIgMj4vZGV2L251bGw7IH0KIyBsZWN0dXJlIGQndW5lIGxpZ25lIHNhbnMg
cHJvY2Vzc3VzIHN1cHBsZW1lbnRhaXJlIDogcmQgVkFSIGZpY2hpZXIgW2RlZmF1dF0KcmQoKSB7
IGV2YWwgIiQxPSIgOyBbIC1zICIkMiIgXSAmJiB7IHJlYWQgLXIgIiQxIiA8ICIkMiIgfHwgOjsg
fTsgZXZhbCAiWyAtbiBcIlwkJDFcIiBdIHx8ICQxPVwkezMtfSI7IH0KdXBfbm93KCkgeyBfdXB0
PTA7IHJlYWQgLXIgX3VwdCBfdXByIDwgIiR7UVBfVVBUSU1FOi0vcHJvYy91cHRpbWV9IiAyPi9k
ZXYvbnVsbDsgVVA9JHtfdXB0JSUuKn07IGNhc2UgIiRVUCIgaW4gJyd8KlshMC05XSopIFVQPTA7
OyBlc2FjOyB9ICAgIyBtZXQgYSBqb3VyICRVUCAoc2Vjb25kZXMgZGVwdWlzIGxlIGRlbWFycmFn
ZSA7IFFQX1VQVElNRSA6IGJhbmMgZCdlc3NhaSkKYm9vdF9pZCgpIHsgaWYgWyAtbiAiJFFQX0JP
T1RfSUQiIF07IHRoZW4gQk9PVD0kUVBfQk9PVF9JRDsgZWxzZSByZWFkIC1yIEJPT1QgPCAvcHJv
Yy9zeXMva2VybmVsL3JhbmRvbS9ib290X2lkOyBmaTsgfQojIHY2IDogbnVtZXJvIGRlIGRlbWFy
cmFnZS4gJFNUL2Jvb3Rfc2VxID0gImJvb3RfaWQgbnVtZXJvIiA7IGxlIGxhbmNldXIgbCdpbmNy
ZW1lbnRlIGEgY2hhcXVlIG5vdXZlYXUgZGVtYXJyYWdlIChib290X3NlcV9idW1wKSwKIyBsZXMg
YXV0cmVzIGxlIGxpc2VudCAoYm9vdF9zZXFfbm93IHBvc2UgU0VRLCBlbiBjb21wdGFudCAxIGRl
IHBsdXMgc2kgbGUgZmljaGllciB2aWVudCBkJ3VuIGF1dHJlIGRlbWFycmFnZSkuIElsIHBlcm1l
dCBkZQojIGZhaXJlIGV4cGlyZXIsIGFwcmVzIHVuIG5vbWJyZSBkZSBkZW1hcnJhZ2VzLCBjZSBx
dWkgYSBldGUgZGF0ZSBhIGwnaG9ybG9nZSBkZSAxOTcwIChzYW5zIHJlc2VhdSwgbCdoZXVyZSBu
J2VzdCBwYXMgZmlhYmxlKS4KYm9vdF9zZXFfbm93KCkgeyBib290X2lkOyBfc2I9OyBfc3M9MDsg
WyAtcyAiJFNUL2Jvb3Rfc2VxIiBdICYmIHJlYWQgLXIgX3NiIF9zcyA8ICIkU1QvYm9vdF9zZXEi
IDI+L2Rldi9udWxsOyB0b2ludCBfc3MgMDsgU0VRPSRfc3M7IFsgIiRfc2IiID0gIiRCT09UIiBd
IHx8IFNFUT0kKChfc3MgKyAxKSk7IH0KYm9vdF9zZXFfYnVtcCgpIHsgYm9vdF9zZXFfbm93OyBb
ICIkX3NiIiA9ICIkQk9PVCIgXSB8fCBwdXQgIiRTVC9ib290X3NlcSIgIiRCT09UICRTRVEiOyB9
CiMgRW50aWVycyBzdXJzIHBvdXIgJCgoICkpIDogZW4gbW9kZSBQT1NJWCwgdW5lIGVycmV1ciBh
cml0aG1ldGlxdWUgKCIxMngiLCBvdSAiMDgiIGx1IGVuIG9jdGFsKSBBUlJFVEUgbGUgc2hlbGwu
CiMgU2V1bHMgbGVzIGNoaWZmcmVzIHNvbnQgYWNjZXB0ZXMgOyBsZXMgemVyb3MgZGUgdGV0ZSBz
b250IHJldGlyZXMuCmludCgpIHsgY2FzZSAiJDEiIGluICcnfCpbITAtOV0qKSBlY2hvICIkezI6
LTB9Ijs7ICopIF9pPSR7MSMiJHsxJSVbITBdKn0ifTsgZWNobyAiJHtfaTotMH0iOzsgZXNhYzsg
fQp0b2ludCgpIHsgZXZhbCAiY2FzZSBcIlwkJDFcIiBpbiAnJ3wqWyEwLTldKikgJDE9XCR7Mjot
MH07OyAqKSAkMT1cJHskMSNcIlwkeyQxJSVbITBdKn1cIn07ICQxPVwkeyQxOi0wfTs7IGVzYWMi
OyB9ICAgICMgdG9pbnQgVkFSIFtkZWZhdXRdIDogc2FucyBwcm9jZXNzdXMKCiMgRWNyaXR1cmUg
YXRvbWlxdWUgOiBmaWNoaWVyIHRlbXBvcmFpcmUgZHUgbWVtZSBkb3NzaWVyLCBwdWlzIHJlbm9t
bWFnZS4KcHV0KCkgeyBlY2hvICIkMiIgPiAiJDEudG1wLiQkIiAyPi9kZXYvbnVsbCAmJiBtdiAt
ZiAiJDEudG1wLiQkIiAiJDEiIDI+L2Rldi9udWxsOyB9CmdldCgpIHsgaWYgWyAtcyAiJDEiIF07
IHRoZW4gaGVhZCAtbjEgIiQxIjsgZWxzZSBlY2hvICIkMiI7IGZpOyB9CiMgUmVzdWx0YXQgZGUg
bGEgZGVybmllcmUgbWlzZSBhIGpvdXIgOiBlbiBtZW1vaXJlIHZpdmUgKGx1IHBhciBsZXMgYW5j
aWVubmVzIHZlcnNpb25zIGQnT3BlblFpYXJhKSBFVCBzdXIgbGEgY2FydGUKIyAoaWwgc3Vydml0
IGEgdW4gcmVkZW1hcnJhZ2UpLiBFY3JpdCBzZXVsZW1lbnQgbG9ycyBkJ3VuZSBtaXNlIGEgam91
ciBvdSBkJ3VuIHJldG91ciA6IHVzdXJlIG5lZ2xpZ2VhYmxlLgpyZXN1bHQoKSB7IHB1dCAiJFJV
Ti9sYXN0X3VwZGF0ZV9yZXN1bHQiICIkMSI7IHB1dCAiJFNUL2xhc3RfdXBkYXRlX3Jlc3VsdCIg
IiQxIjsgfQpsYXN0X3Jlc3VsdCgpIHsgcmQgX2xyICIkUlVOL2xhc3RfdXBkYXRlX3Jlc3VsdCIg
IiI7IFsgLW4gIiRfbHIiIF0gfHwgcmQgX2xyICIkU1QvbGFzdF91cGRhdGVfcmVzdWx0IiBhdWN1
bjsgfQpzaGFfb2YoKSB7IHNoYTI1NnN1bSAiJDEiIDI+L2Rldi9udWxsIHwgY3V0IC1kJyAnIC1m
MTsgfQojIHY1IDogbCdhcHBsaWNhdGlvbiBsYW5jZWUgcGFyIGxlIGxhbmNldXIuIGxpdmVfY2hp
bGQgcG9zZSBDSCBhIHNvbiBudW1lcm8gZGUgcHJvY2Vzc3VzLCBzZXVsZW1lbnQgc2kgY2UgbnVt
ZXJvIHZpdCBFVCBwb3J0ZSBsZQojIG5vbSBkZSBsJ2FwcGxpY2F0aW9uIChvcGVucWlhcmFkLCBv
dSBvcGVucWlhcmFkLm9sZCBlbiByZXBsaSB1bHRpbWUpIDogJFNUL2NoaWxkIGVzdCBzdXIgbGEg
Y2FydGUsIGlsIHN1cnZpdCBhIHVuIHJlZGVtYXJyYWdlLAojIGV0IGxlIG51bWVybyBwZXV0IGF2
b2lyIGV0ZSByZXByaXMgcGFyIHVuIGF1dHJlIHByb2dyYW1tZSAoZHJvcGJlYXIsIGhsY2FtZC4u
LikgcXUndW4gYXJyZXQgbmUgZG9pdCBqYW1haXMgdG91Y2hlci4KQVBQX0NPTU09JHtRUF9BUFBf
Q09NTTotb3BlbnFpYXJhZH0KbGl2ZV9jaGlsZCgpIHsKICByZCBDSCAiJFNUL2NoaWxkIiAwOyB0
b2ludCBDSCAwCiAgWyAiJENIIiAhPSAwIF0gJiYga2lsbCAtMCAiJENIIiAyPi9kZXYvbnVsbCB8
fCB7IENIPTA7IHJldHVybiAxOyB9CiAgX2M9OyByZWFkIC1yIF9jIDwgL3Byb2MvJENIL2NvbW0g
Mj4vZGV2L251bGwKICBjYXNlICIkX2MiIGluICIkQVBQX0NPTU0ifCIkQVBQX0NPTU0iLiopIHJl
dHVybiAwOzsgZXNhYwogIENIPTA7IHJldHVybiAxCn0KCiMgRG9zc2llciBkJ3VuIGVtcGxhY2Vt
ZW50IDogZmFjdG9yeSBzdXIgL2RhdGEgKHRvdWpvdXJzIHByZXNlbnQpLCBnb29kIGV0IG5ldyBz
dXIgL21lZGlhLgpzZCgpIHsgY2FzZSAiJDEiIGluIGZhY3RvcnkpIGVjaG8gIiRRUC9zbG90cy9m
YWN0b3J5Ijs7ICopIGVjaG8gIiRCVUxLL3Nsb3RzLyQxIjs7IGVzYWM7IH0KIyBPcmRyZSBkZSBy
ZXBsaSA6IG5ldyAtPiBnb29kIC0+IHByZXYgKGxhIHZlcnNpb24gdmFsaWRlZSBhdmFudCBnb29k
KSAtPiBmYWN0b3J5IChvcmlnaW5lLCBzdXIgL2RhdGEpCm9yZGVyKCkgeyBjYXNlICIkMSIgaW4g
bmV3KSBlY2hvICJuZXcgZ29vZCBwcmV2IGZhY3RvcnkiOzsgZ29vZCkgZWNobyAiZ29vZCBwcmV2
IGZhY3RvcnkiOzsgcHJldikgZWNobyAicHJldiBmYWN0b3J5Ijs7ICopIGVjaG8gImZhY3Rvcnki
OzsgZXNhYzsgfQoKIyBBZ2UgZCd1biBldmVuZW1lbnQgZGF0ZSAiYm9vdF9pZCB1cHRpbWUgaG9y
bG9nZSIgOiBhZ2Vfb2YgQiBVIFcgcG9zZSBBR0UgKHNlY29uZGVzKSwgbWVzdXJlIHN1ciBsJ3Vw
dGltZSBzaSBtZW1lIGRlbWFycmFnZSwKIyBzdXIgbCdob3Jsb2dlIG11cmFsZSBzaW5vbiBldCBz
ZXVsZW1lbnQgc2kgZWxsZSBlc3QgcGxhdXNpYmxlIGRlcyBkZXV4IGNvdGVzIChhcHJlcyAyMDIz
LTExLCBjcm9pc3NhbnRlKSA7IEFHRT0tMSBzaSBpbmNvbm51CiMgKGF1dHJlIGRlbWFycmFnZSwg
aG9ybG9nZSBkZSAxOTcwIGQndW4gY290ZSkuIFVuIFcgc2V1bCAoYW5jaWVuIGZvcm1hdCwgbnVt
ZXJpcXVlKSB2YXV0ICJhdXRyZSBkZW1hcnJhZ2UiLgphZ2Vfb2YoKSB7CiAgX2FiPSQxOyBfYXU9
JDI7IF9hdz0kMzsgQUdFPS0xCiAgYm9vdF9pZDsgdXBfbm93CiAgaWYgWyAtbiAiJF9hYiIgXSAm
JiBbICIkX2FiIiA9ICIkQk9PVCIgXTsgdGhlbiBBR0U9JCgoIFVQIC0gJChpbnQgIiRfYXUiIDAp
ICkpOyBbICIkQUdFIiAtbHQgMCBdICYmIEFHRT0wOyByZXR1cm4gMDsgZmkKICBfYW49JChub3cp
OyBfYXc9JChpbnQgIiRfYXciIDApCiAgaWYgWyAiJF9hbiIgLWd0IDE3MDAwMDAwMDAgXSAmJiBb
ICIkX2F3IiAtZ3QgMTcwMDAwMDAwMCBdICYmIFsgIiRfYW4iIC1nZSAiJF9hdyIgXTsgdGhlbiBB
R0U9JCgoX2FuIC0gX2F3KSk7IGZpCn0KIyBNYXJxdWFnZSBCQUQgOiAiYm9vdF9pZCB1cHRpbWUg
aG9ybG9nZSBudW1lcm9fZGVfZGVtYXJyYWdlIi4gSWwgZXhwaXJlIGFwcmVzIFFQX0JBRF9UVEwg
cyAobWVzdXJlIHN1ciB1cHRpbWUgc2kgbWVtZQojIGRlbWFycmFnZSwgc3VyIGwnaG9ybG9nZSBz
aW5vbiBldCBzZXVsZW1lbnQgc2kgZWxsZSBlc3QgcGxhdXNpYmxlKSBvdSwgcXVhbmQgbCdhZ2Ug
ZXN0IGluY29ubnUgKHBvc2UgYSBsJ2hvcmxvZ2UgZGUgMTk3MCwKIyBwdWlzIHJlZGVtYXJyYWdl
KSwgYXByZXMgUVBfQkFEX0JPT1RTIGRlbWFycmFnZXMgKHY2IDogc2FucyBjZWxhIHVuIGVtcGxh
Y2VtZW50IGVjYXJ0ZSBhdmFudCBsZSByZWdsYWdlIGRlIGwnaGV1cmUgbCdldGFpdAojIHBvdXIg
dG91am91cnMpLiBFbiBjYXMgZGUgZG91dGUsIGwnZW1wbGFjZW1lbnQgcmVzdGUgZWNhcnRlLgpC
QURfVFRMPSR7UVBfQkFEX1RUTDotMTgwMH0KQkFEX0JPT1RTPSR7UVBfQkFEX0JPT1RTOi0yfQpz
bG90X2JhZCgpIHsKICBfZj0kKHNkICIkMSIpL0JBRAogIFsgLWUgIiRfZiIgXSB8fCByZXR1cm4g
MQogIFsgIiQxIiA9IGZhY3RvcnkgXSAmJiByZXR1cm4gMSAgICAgICAjIGxlIGJpbmFpcmUgZCdv
cmlnaW5lIG4nZXN0IGphbWFpcyBlY2FydGUKICBfYj07IF91PTsgX3c9OyBfcT07IHJlYWQgLXIg
X2IgX3UgX3cgX3EgPCAiJF9mIiAyPi9kZXYvbnVsbAogIFsgLXogIiRfdSIgXSAmJiBbIC16ICIk
X3ciIF0gJiYgeyBfdz0kX2I7IF9iPTsgfSAgICAgICAgIyBhbmNpZW4gZm9ybWF0IDogdW5lIHNl
dWxlIGRhdGUKICAjIHY2IDogdW4gbWFycXVhZ2UgdmlkZSBvdSBpbGxpc2libGUgKGZpY2hpZXIg
dHJvbnF1ZSkgbmUgdmF1dCByaWVuIDogaWwgZXN0IHJldGlyZS4gVW5lIGJvdWNsZSBkJ2FycmV0
cyBsZSByZXBvc2VyYWl0CiAgIyBjb3JyZWN0ZW1lbnQgZW4gcXVlbHF1ZXMgc2Vjb25kZXMgOyBs
ZSBnYXJkZXIgYXVyYWl0IGVjYXJ0ZSBsJ2VtcGxhY2VtZW50IHBvdXIgdG91am91cnMuCiAgY2Fz
ZSAiJHtfdTotMH0ke193Oi0wfSIgaW4gKlshMC05XSopIHJtIC1mICIkX2YiOyBsb2cgIm1hcnF1
YWdlIEJBRCBkZSAkMSBpbGxpc2libGUgOiByZXRpcmUiOyByZXR1cm4gMTs7IGVzYWMKICBbIC1u
ICIkX3UkX3ciIF0gfHwgeyBybSAtZiAiJF9mIjsgbG9nICJtYXJxdWFnZSBCQUQgZGUgJDEgdmlk
ZSA6IHJldGlyZSI7IHJldHVybiAxOyB9CiAgYWdlX29mICIkX2IiICIkX3UiICIkX3ciCiAgaWYg
WyAiJEFHRSIgLWx0IDAgXTsgdGhlbgogICAgX2FnZT0wCiAgICBjYXNlICIkX3EiIGluICcnfCpb
ITAtOV0qKSA7OyAqKSBib290X3NlcV9ub3c7IFsgJCgoU0VRIC0gJChpbnQgIiRfcSIgMCkpKSAt
Z2UgIiRCQURfQk9PVFMiIF0gJiYgX2FnZT0kQkFEX1RUTDs7IGVzYWMKICBlbHNlIF9hZ2U9JEFH
RTsgZmkKICBbICIkX2FnZSIgLWx0ICIkQkFEX1RUTCIgXSAmJiByZXR1cm4gMAogIHJtIC1mICIk
X2YiOyByZXR1cm4gMQp9CiMgRW1wbGFjZW1lbnQgdXRpbGlzYWJsZSA6IGJpbmFpcmUgbm9uIHZp
ZGUsIG5vbiBCQUQsIGVtcHJlaW50ZSBjb25mb3JtZSAoZXhpZ2VlIHBvdXIgZ29vZCBldCBuZXcp
LiBQb3NlICRWU0hBLgpzbG90X3ZhbGlkKCkgewogIF9kPSQoc2QgIiQxIik7IFZTSEE9CiAgWyAt
cyAiJF9kL29wZW5xaWFyYWQiIF0gfHwgcmV0dXJuIDEKICBzbG90X2JhZCAiJDEiICYmIHJldHVy
biAxCiAgaWYgWyAtcyAiJF9kL29wZW5xaWFyYWQuc2hhMjU2IiBdOyB0aGVuCiAgICBfd2FudD07
IHJlYWQgLXIgX3dhbnQgX3ggPCAiJF9kL29wZW5xaWFyYWQuc2hhMjU2IgogICAgVlNIQT0kKHNo
YV9vZiAiJF9kL29wZW5xaWFyYWQiKQogICAgWyAiJF93YW50IiA9ICIkVlNIQSIgXSB8fCByZXR1
cm4gMQogIGVsc2UKICAgIFsgIiQxIiA9IGZhY3RvcnkgXSB8fCByZXR1cm4gMQogIGZpCiAgcmV0
dXJuIDAKfQptYXJrX2JhZCgpIHsgWyAiJDEiID0gZmFjdG9yeSBdICYmIHJldHVybiAwOyBib290
X3NlcV9ub3c7IHVwX25vdzsgcHV0ICIkKHNkICIkMSIpL0JBRCIgIiRCT09UICRVUCAkKG5vdykg
JFNFUSI7IGxvZyAiZW1wbGFjZW1lbnQgJDEgbWFycXVlIEJBRCI7IH0KU1RBQkxFPSQoaW50ICIk
e1FQX1NUQUJMRV9TRUM6LTEyMH0iIDEyMCkKR0FQPSQoaW50ICIke1FQX0dBUF9TRUM6LTE1fSIg
MTUpICAgICAgICAgICAgIyBwYXVzZSBkZSBsYSBib3VjbGUgZGUgYm9vdC5zaCBlbnRyZSBkZXV4
IGxhbmNlbWVudHMgKDEwIHMpICsgbWFyZ2UKTUFYRkFJTD0kKGludCAiJHtRUF9NQVhGQUlMOi0z
fSIgMykKTUFYU1RBUlQ9JChpbnQgIiR7UVBfTUFYU1RBUlQ6LTZ9IiA2KQpib290X2lkOyB1cF9u
b3cKYm9vdF9zZXFfYnVtcCAgICAgICAgICAjIHY2IDogbnVtZXJvIGRlIGRlbWFycmFnZSAodW5l
IGVjcml0dXJlIHBhciBkZW1hcnJhZ2UsIHNldWxlbWVudCBzaSBsZSBkZW1hcnJhZ2UgYSBjaGFu
Z2UpCgojIFZlcnJvdSA6IHVuIHNldWwgbGFuY2V1ciAocHVpcyB1bmUgc2V1bGUgYXBwbGljYXRp
b24sIHF1aSBoZXJpdGUgZHUgcGlkKSBhIGxhIGZvaXMuCkxPQ0s9JFJVTi9sYXVuY2gubG9jawpp
ZiAhIG1rZGlyICIkTE9DSyIgMj4vZGV2L251bGw7IHRoZW4KICByZCBvcCAiJExPQ0svcGlkIiAw
CiAgWyAiJG9wIiA9IDAgXSAmJiB7IHNsZWVwIDE7IHJkIG9wICIkTE9DSy9waWQiIDA7IH0gICAg
ICAjIHY1IDogdmVycm91IGVuIGNvdXJzIGRlIGNyZWF0aW9uIChwaWQgcGFzIGVuY29yZSBlY3Jp
dCkgOiBuZSBwYXMgbGUgdm9sZXIKICBpZiBbICIkb3AiICE9IDAgXSAmJiBraWxsIC0wICIkb3Ai
IDI+L2Rldi9udWxsOyB0aGVuIHNsZWVwIDU7IGV4aXQgMDsgZmkKICBybSAtcmYgIiRMT0NLIjsg
bWtkaXIgIiRMT0NLIiAyPi9kZXYvbnVsbCB8fCBleGl0IDEKZmkKZWNobyAkJCA+ICIkTE9DSy9w
aWQiCgojIDEuIEJpbGFuIGR1IGxhbmNlbWVudCBwcmVjZWRlbnQgKHNldWxlbWVudCBzJ2lsIGEg
ZXUgbGlldSBwZW5kYW50IGNlIGRlbWFycmFnZSkKcmQgcHNsb3QgIiRTVC9ydW5uaW5nX3Nsb3Qi
ICIiCnJkIHBib290ICIkU1QvcnVuX2Jvb3QiICIiCnJkIHB1cCAiJFNUL3J1bl91cCIgMApmc2xv
dD07IGZhaWxzPTA7IFsgLXMgIiRTVC9mYWlscyIgXSAmJiByZWFkIC1yIGZzbG90IGZhaWxzIDwg
IiRTVC9mYWlscyIKZmFpbHM9JChpbnQgIiRmYWlscyIgMCk7IFsgIiRmc2xvdCIgPSAiJHBzbG90
IiBdIHx8IGZhaWxzPTAgICAgICAjIGxlIGNvbXB0ZXVyIGFwcGFydGllbnQgYSB1biBlbXBsYWNl
bWVudAppZiBbIC1uICIkcHNsb3QiIF0gJiYgWyAiJHBib290IiA9ICIkQk9PVCIgXTsgdGhlbgog
IGR1cj0kKCggVVAgLSAkKGludCAiJHB1cCIgMCkgKSkKICBpZiBbIC1lICIkU1QvZXhwZWN0ZWRf
c3RvcCIgXTsgdGhlbgogICAgbG9nICIkcHNsb3QgYXJyZXRlIHZvbG9udGFpcmVtZW50IGFwcmVz
IH4ke2R1cn0gcyI7IGZhaWxzPTAKICBlbGlmIFsgIiRkdXIiIC1sdCAkKChTVEFCTEUgKyBHQVAp
KSBdOyB0aGVuCiAgICBmYWlscz0kKChmYWlscyArIDEpKQogICAgbG9nICIkcHNsb3Qgcydlc3Qg
YXJyZXRlIGFwcmVzIH4ke2R1cn0gcyA6IGFycmV0IHJhcGlkZSAkZmFpbHMvJE1BWEZBSUwiCiAg
ICBpZiBbICIkZmFpbHMiIC1nZSAiJE1BWEZBSUwiIF07IHRoZW4KICAgICAgaWYgWyAiJHBzbG90
IiA9IGZhY3RvcnkgXTsgdGhlbgogICAgICAgICMgdjYgOiBmYWN0b3J5IG4nZXN0IGphbWFpcyBl
Y2FydGUgOyBsZSBjb21wdGV1ciBjb250aW51ZSBldCwgdGFudCBxdSdpbCByZXN0ZSBhdSBwbGFm
b25kLCBsJ2FwcGxpY2F0aW9uIGVzdCBsYW5jZWUKICAgICAgICAjIFNBTlMgYXBwLmVudiAodW4g
cmVnbGFnZSBHbyBpbnZhbGlkZSwgR09NRU1MSU1JVCBwYXIgZXhlbXBsZSwgYXJyZXRlIGwnZXhl
Y3V0aW9uIEdvIGF1IGRlbWFycmFnZSwgcG91ciB0b3V0ZXMgbGVzIHZlcnNpb25zKQogICAgICAg
IGxvZyAiZmFjdG9yeSA6ICRmYWlscyBhcnJldHMgcmFwaWRlcywgcHJvY2hhaW4gbGFuY2VtZW50
IHNhbnMgYXBwLmVudiIKICAgICAgZWxzZQogICAgICAgIFsgIiRwc2xvdCIgIT0gbWVkaWEtb2xk
IF0gJiYgbWFya19iYWQgIiRwc2xvdCIKICAgICAgICBpZiBbICIkcHNsb3QiID0gbmV3IF07IHRo
ZW4gcm0gLWYgIiRTVC90cmlhbCI7IHB1dCAiJFNUL25ld19zdGFydHMiIDA7IHJlc3VsdCAiZWNo
ZWM6IG5ldyBwbGFudGUgYXUgZGVtYXJyYWdlLCByZXRvdXIgYSBnb29kIjsgZmkKICAgICAgICBm
YWlscz0wCiAgICAgIGZpCiAgICBmaQogIGVsc2UKICAgIGxvZyAiJHBzbG90IHMnZXN0IGFycmV0
ZSBhcHJlcyB+JHtkdXJ9IHMiOyBmYWlscz0wCiAgZmkKZmkKcHV0ICIkU1QvZmFpbHMiICIkcHNs
b3QgJGZhaWxzIgpybSAtZiAiJFNUL2V4cGVjdGVkX3N0b3AiCgojIDIuIENob2l4IGRlIGwnZW1w
bGFjZW1lbnQKcmQgYWN0aXZlICIkU1QvYWN0aXZlIiBnb29kCmNob3Nlbj07IEJJTj0KZm9yIHMg
aW4gJChvcmRlciAiJGFjdGl2ZSIpOyBkbwogIGlmIHNsb3RfdmFsaWQgIiRzIjsgdGhlbgogICAg
aWYgWyAiJHMiID0gbmV3IF07IHRoZW4KICAgICAgcmQgbnMgIiRTVC9uZXdfc3RhcnRzIiAwOyBu
cz0kKCggJChpbnQgIiRucyIgMCkgKyAxICkpCiAgICAgIGlmIFsgIiRucyIgLWd0ICIkTUFYU1RB
UlQiIF07IHRoZW4KICAgICAgICBsb2cgIm5ldyBsYW5jZSAkKChucy0xKSkgZm9pcyBzYW5zIHZh
bGlkYXRpb24gOiBlY2FydGUgKGJvdWNsZSBkZSByZWRlbWFycmFnZXMgPykiCiAgICAgICAgbWFy
a19iYWQgbmV3OyBwdXQgIiRTVC9uZXdfc3RhcnRzIiAwOyBybSAtZiAiJFNUL3RyaWFsIgogICAg
ICAgIHJlc3VsdCAiZWNoZWM6IG5ldyBlY2FydGUgYXByZXMgJCgobnMtMSkpIGxhbmNlbWVudHMg
c2FucyB2YWxpZGF0aW9uIgogICAgICAgIGNvbnRpbnVlCiAgICAgIGZpCiAgICAgIHB1dCAiJFNU
L25ld19zdGFydHMiICIkbnMiCiAgICBmaQogICAgY2hvc2VuPSRzOyBicmVhawogIGZpCiAgbG9n
ICJlbXBsYWNlbWVudCAkcyBpbnV0aWxpc2FibGUsIGVzc2FpIGR1IHN1aXZhbnQiCmRvbmUKaWYg
WyAteiAiJGNob3NlbiIgXTsgdGhlbgogICMgdjYgOiBzaSB1bmUgZW1wcmVpbnRlIGFjY29tcGFn
bmUgbGEgY29waWUgZGUgc2Vjb3VycyAoZWNyaXRlIHBhciBxcC11cGRhdGUpLCBlbGxlIGRvaXQg
Y29ycmVzcG9uZHJlIDsgc2FucyBlbXByZWludGUsIGxhIGNvcGllCiAgIyBkJ29yaWdpbmUgKDI0
LzEwLCBhbnRlcmlldXJlIGEgUWlhcmEgUGx1cykgZXN0IGFjY2VwdGVlIHRlbGxlIHF1ZWxsZSwg
Y29tbWUgYXZhbnQuCiAgb2xkb2s9MAogIGlmIFsgLXMgIiRPTEQiIF07IHRoZW4KICAgIG9sZG9r
PTE7IFZTSEE9JChzaGFfb2YgIiRPTEQiKQogICAgaWYgWyAtcyAiJE9MRC5zaGEyNTYiIF07IHRo
ZW4gX293PTsgcmVhZCAtciBfb3cgX294IDwgIiRPTEQuc2hhMjU2IjsgWyAiJF9vdyIgPSAiJFZT
SEEiIF0gfHwgeyBvbGRvaz0wOyBsb2cgImNvcGllIGRlIHNlY291cnMgJE9MRCA6IGVtcHJlaW50
ZSBkaWZmZXJlbnRlIGRlICRPTEQuc2hhMjU2LCBpZ25vcmVlIjsgfTsgZmkKICBmaQogIGlmIFsg
IiRvbGRvayIgPSAxIF07IHRoZW4KICAgIGxvZyAiYXVjdW4gZW1wbGFjZW1lbnQgdmFsaWRlLCBy
ZXBsaSBzdXIgJE9MRCIKICAgIEJJTj0kT0xEOyBjaG9zZW49bWVkaWEtb2xkCiAgZWxzZQogICAg
bG9nICJBVUNVTiBiaW5haXJlIHV0aWxpc2FibGUsIG5vdXZlbCBlc3NhaSBkYW5zIDMwIHMiCiAg
ICBybSAtcmYgIiRMT0NLIjsgc2xlZXAgIiR7UVBfTk9CSU5fU0xFRVA6LTMwfSI7IGV4aXQgMQog
IGZpCmVsc2UKICBCSU49JChzZCAiJGNob3NlbiIpL29wZW5xaWFyYWQKZmkKIyBVbiBlc3NhaSAo
bmV3KSBpbnV0aWxpc2FibGUgbWV0IGZpbiBhIGwnZXNzYWkgOiByZXRvdXIgZHVyYWJsZSBhIGdv
b2QuIFVuIHJlcGxpIGRlcHVpcyBnb29kIG91IHByZXYgcmVzdGUKIyB0ZW1wb3JhaXJlIDogbCdl
bXBsYWNlbWVudCBhY3RpZiBuZSBjaGFuZ2UgcGFzLCBpbCBzZXJhIHJldGVudGUgYXUgcHJvY2hh
aW4gbGFuY2VtZW50IChtYXJxdWFnZSBCQUQgZXhwaXJlKS4KaWYgWyAiJGFjdGl2ZSIgPSBuZXcg
XSAmJiBbICIkY2hvc2VuIiAhPSBuZXcgXTsgdGhlbgogIHB1dCAiJFNUL2FjdGl2ZSIgZ29vZDsg
cHV0ICIkU1QvbmV3X3N0YXJ0cyIgMAogIGlmIFsgLWUgIiRTVC90cmlhbCIgXTsgdGhlbiBybSAt
ZiAiJFNUL3RyaWFsIjsgcmVzdWx0ICJlY2hlYzogbmV3IGludXRpbGlzYWJsZSwgcmV0b3VyIGEg
Z29vZCI7IGZpCiAgbG9nICJlc3NhaSBhYmFuZG9ubmUgKG5ldyBpbnV0aWxpc2FibGUpIDogZW1w
bGFjZW1lbnQgYWN0aWYgZ29vZCwgbGFuY2UgOiAkY2hvc2VuIgplbGlmIFsgIiRjaG9zZW4iICE9
ICIkYWN0aXZlIiBdOyB0aGVuCiAgbG9nICJyZXBsaSB0ZW1wb3JhaXJlIHN1ciAkY2hvc2VuICgk
YWN0aXZlIGludXRpbGlzYWJsZSkiCmZpCiMgdjQuMSA6IHVuIGVzc2FpIGRvbnQgbGUgbWFycXVl
dXIgYSBkaXNwYXJ1IChlY3JpdHVyZSBwZXJkdWUgcGFyIGxhIGNhcnRlIFNEIGxvcnMgZGUgbGEg
cGFubmUgZHUgMjYvMTAgYSAyMCBoIDI4IDoKIyBhY3RpdmU9bmV3IGVzdCByZXN0ZSwgdHJpYWwg
bm9uKSBuZSBzZXJhaXQgamFtYWlzIHZhbGlkZSBuaSBhbm51bGUgcGFyIGxlIHN1cnZlaWxsYW50
LiBMZSBtYXJxdWV1ciBlc3QgcmVjcmVlIDoKIyBsJ2Vzc2FpIHJlcHJlbmQgc2VzIHJlZ2xlcyAo
dmFsaWRhdGlvbiBhcHJlcyAzIG1pbiBkZSBib25uZSBzYW50ZSwgcmV0b3VyIGFycmllcmUgc3Vy
IGJsb2NhZ2VzLCA2IGxhbmNlbWVudHMgYXUgcGx1cykuCmlmIFsgIiRjaG9zZW4iID0gbmV3IF0g
JiYgWyAhIC1lICIkU1QvdHJpYWwiIF07IHRoZW4KICBwdXQgIiRTVC90cmlhbCIgIiQobm93KSAk
VlNIQSI7IHN5bmMKICBsb2cgIm1hcnF1ZXVyIGQnZXNzYWkgYWJzZW50IHBvdXIgbmV3IChlY3Jp
dHVyZSBwZXJkdWUgPykgOiByZWNyZWUsIGwnZXNzYWkgY29udGludWUiCiAgcmVzdWx0ICJlc3Nh
aSBlbiBjb3VycyA6ICQoZWNobyAiJFZTSEEiIHwgY3V0IC1jMS0xMikgKG1hcnF1ZXVyIHJlY3Jl
ZSkiCmZpClsgLXggIiRCSU4iIF0gfHwgY2htb2QgNzU1ICIkQklOIiAyPi9kZXYvbnVsbAoKIyAz
LiBSZWdsYWdlcyBkZSBsJ2V4ZWN1dGlvbiBHbyAobWVtb2lyZSkgOiBzZXVsZXMgcXVlbHF1ZXMg
dmFyaWFibGVzIGNvbm51ZXMgc29udCBhY2NlcHRlZXMsIGF2ZWMgdW5lIHZhbGV1ciBkZSBmb3Jt
ZSBjb25udWUKIyAodjYgOiB1biBHT01FTUxJTUlUIG1hbCBmb3JtZSBmYWl0IHNvcnRpciBsJ2V4
ZWN1dGlvbiBHbyBkZXMgbGUgZGVtYXJyYWdlIDsgdW4gZmljaGllciBhYmltZSBuZSBkb2l0IHBh
cyByZW5kcmUgdG91dGVzIGxlcwojIHZlcnNpb25zIGlubGFuY2FibGVzKS4gQXByZXMgTUFYRkFJ
TCBhcnJldHMgcmFwaWRlcyBkZSBmYWN0b3J5LCBsZSBmaWNoaWVyIGVzdCBpZ25vcmUgZW4gZW50
aWVyLgpub2Vudj0wOyBbICIkY2hvc2VuIiA9IGZhY3RvcnkgXSAmJiBbICIkcHNsb3QiID0gZmFj
dG9yeSBdICYmIFsgIiRmYWlscyIgLWdlICIkTUFYRkFJTCIgXSAmJiBub2Vudj0xCmlmIFsgLXMg
IiRRUC9hcHAuZW52IiBdICYmIFsgIiRub2VudiIgPSAwIF07IHRoZW4KICB3aGlsZSBJRlM9Jz0n
IHJlYWQgLXIgayB2OyBkbwogICAgWyAtbiAiJHYiIF0gfHwgY29udGludWUKICAgIG9rPTAKICAg
IGNhc2UgIiRrIiBpbgogICAgICBHT0dDKSAgICAgICAgY2FzZSAiJHYiIGluIG9mZnxbMC05XXxb
MC05XVswLTldfFswLTldWzAtOV1bMC05XXxbMC05XVswLTldWzAtOV1bMC05XSkgb2s9MTs7IGVz
YWMgOzsKICAgICAgR09NRU1MSU1JVCkgIGNhc2UgIiR2IiBpbiBvZmYpIG9rPTE7OyAqWyEwLTlB
LVphLXpdKikgOzsgWzAtOV0qKSBjYXNlICIke3YjIiR7diUlWyEwLTldKn0ifSIgaW4gJyd8QnxL
aUJ8TWlCfEdpQnxUaUJ8S0J8TUJ8R0J8VEIpIG9rPTE7OyBlc2FjOzsgZXNhYyA7OwogICAgICBH
T01BWFBST0NTKSAgY2FzZSAiJHYiIGluIFsxLTldfFsxLTldWzAtOV0pIG9rPTE7OyBlc2FjIDs7
CiAgICAgIEdPVFJBQ0VCQUNLKSBjYXNlICIkdiIgaW4gbm9uZXxzaW5nbGV8YWxsfHN5c3RlbXxj
cmFzaCkgb2s9MTs7IGVzYWMgOzsKICAgICAgR09ERUJVRykgICAgIGNhc2UgIiR2IiBpbiAqWyFB
LVphLXowLTlfLD0uLV0qKSA7OyAqKSBvaz0xOzsgZXNhYyA7OwogICAgZXNhYwogICAgaWYgWyAi
JG9rIiA9IDEgXTsgdGhlbiBleHBvcnQgIiRrPSR2IjsgZWxzZSBsb2cgImFwcC5lbnYgOiBsaWdu
ZSByZWZ1c2VlICgkKGVjaG8gIiRrIiB8IGN1dCAtYzEtMjApPSQoZWNobyAiJHYiIHwgY3V0IC1j
MS0yMCkpIjsgZmkKICBkb25lIDwgIiRRUC9hcHAuZW52IgplbGlmIFsgIiRub2VudiIgPSAxIF07
IHRoZW4gbG9nICJhcHAuZW52IGlnbm9yZSAoZmFjdG9yeSBhcnJldGUgJGZhaWxzIGZvaXMgZGUg
c3VpdGUpIgpmaQoKIyA0LiBTdXJ2ZWlsbGFuY2UgbXV0dWVsbGUgOiBzaSBsZSBzdXJ2ZWlsbGFu
dCBuZSB0b3VybmUgcGx1cywgbGUgbGFuY2V1ciBsZSByZWxhbmNlIChpbCByZWxhbmNlIGwnYXBw
bGljYXRpb24sIGV0IGludmVyc2VtZW50KQppZiBbIC1mICIkUVAvcXAtZ3VhcmQiIF0gJiYgWyAt
eiAiJFFQX05PX0dVQVJEIiBdOyB0aGVuCiAgcmQgZ3AgIiRSVU4vZ3VhcmQubG9jay9waWQiIDAK
ICBpZiBbICIkZ3AiID0gMCBdIHx8ICEga2lsbCAtMCAiJGdwIiAyPi9kZXYvbnVsbDsgdGhlbgog
ICAgbG9nICJzdXJ2ZWlsbGFudCBhYnNlbnQgOiByZWxhbmNlIgogICAgKCBub2h1cCBzaCAiJFFQ
L3FwLWd1YXJkIiA+L2Rldi9udWxsIDI+JjEgJiApCiAgZmkKZmkKCiMgNS4gRXRhdCwgcHVpcyBy
ZW1wbGFjZW1lbnQgcGFyIGwnYXBwbGljYXRpb24gKG1lbWUgcGlkKQpwdXQgIiRTVC9ydW5uaW5n
X3Nsb3QiICIkY2hvc2VuIjsgcHV0ICIkU1QvcnVuX2Jvb3QiICIkQk9PVCI7IHB1dCAiJFNUL3J1
bl91cCIgIiRVUCI7IHB1dCAiJFNUL2NoaWxkIiAiJCQiCnJtIC1mICIkUlVOL2hlYWx0aCIgICAg
ICMgbGEgc2FudGUgZWNyaXRlIHBhciB1biBsYW5jZW1lbnQgcHJlY2VkZW50IG5lIGRvaXQgamFt
YWlzIGV0cmUganVnZWUgcG91ciBjZWx1aS1jaQpsb2cgImRlbWFycmFnZSBkZSAkY2hvc2VuICgk
KGVjaG8gIiRWU0hBIiB8IGN1dCAtYzEtMTIpKSR7R09HQzorIEdPR0M9JEdPR0N9JHtHT01FTUxJ
TUlUOisgR09NRU1MSU1JVD0kR09NRU1MSU1JVH0iCiMgUVBfRVhFQ19TSCA6IHNldWxlbWVudCBw
b3VyIGwnZXNzYWkgYSBibGFuYyBzdXIgbGEgY2FtZXJhLCBvdSAvdG1wIGludGVyZGl0IGwnZXhl
Y3V0aW9uIChub2V4ZWMpIDogbGUgZmF1eCBiaW5haXJlIHkgZXN0IGx1IHBhciBzaC4KaWYgWyAt
biAiJFFQX0VYRUNfU0giIF07IHRoZW4gZXhlYyBzaCAiJEJJTiIgIiRAIjsgZmkKZXhlYyAiJEJJ
TiIgIiRAIgo=
@@FILE qp-guard b94ba190ed9c2ce4c3dad3da36660692654e7757d8aafb53bf0cf33f34e45062
IyEvYmluL3NoCiMgcXAtZ3VhcmQgOiBzdXJ2ZWlsbGFudCBkZSBsYSBjYW1lcmEsIGxhbmNlIHBh
ciBwb3N0X2Jvb3Quc2ggKENsYXVkZSwgMjYvMTAvMjAyNiA7IHYxMCAyOC8xMCA6IGxlIGJvdXRv
biDCqyBSZWRlbWFycmVyIGxhIGNhbWVyYSDCuwojIGRlIEhvbWUgQXNzaXN0YW50IG4nZXN0IHBs
dXMgbGltaXRlIChPUkRFUl9SRUJPT1RfTUFYPTAgPSBzYW5zIGxpbWl0ZSwgcGFyIGRlZmF1dCkg
OyBsZSBidWRnZXQgZGVzIHJlZGVtYXJyYWdlcyBhdXRvbWF0aXF1ZXMgcmVzdGUgOyB2OSAyOC8x
MCA6IGF1Y3VuZSBjb21tYW5kZSBleHRlcm5lIG5lIHBldXQKIyBmaWdlciBsYSBib3VjbGUgKGZi
eHVwc3RhcnRjdGwsIGZieGJ1c2N0bCwgc3luYywgZHJvcGJlYXIgbGFuY2VzIGF2ZWMgdW4gZGVs
YWkgbWF4aW1hbCA6IGJvdW5kZWQpLCBvcmRyZSBzc2gtcmVzdGFydCB2ZXJpZmllCiMgKGF0dGVu
dGUgZGUgbCdhcnJldCBkZSBsJ2FuY2llbiBkcm9wYmVhciAyMjIyLCBjb250cm9sZSBkZSBsJ2Vj
b3V0ZSwgam91cm5hbCBleHBsaWNpdGUpIDsgdjggMjcvMTAgOiBkcm9wYmVhciAyMjIyIHJlbGFu
Y2UgYXZlYwojIG1haW50aWVuIGRlIGNvbm5leGlvbiAoLUsgMzApLCBvcmRyZSBzc2gtcmVzdGFy
dCBkZSBIb21lIEFzc2lzdGFudCAocmVsYW5jZSBkZXMgZGV1eCBkcm9wYmVhciwgNiBwYXIgaGV1
cmUgYXUgcGx1cyksIGNvZGVjIHZpZGVvCiMgZGVtYW5kZSBhIGhsY2FtZCAoLS11c2UtaDI2NC8t
LXVzZS1oMjY1KSBkYW5zIGxlIHJlbGV2w6kgOyB2NyAyNy8xMCAodjYgZGUgbGEgc2Vzc2lvbiBC
ICsgcmVnbGUgdmlkZW8pIDogaGxjYW1kIGFic2VudCBkZXB1aXMgVklERU9fR09ORV9TRUMgLT4g
cmVkZW1hcnJhZ2UKIyBib3JuZSBwYXIgbGUgYnVkZ2V0IGV4aXN0YW50IChjb3JyZWN0aW9uIGR1
IGNoaWVuIGRlIGdhcmRlIGR1IG1pY3JvY29udHJvbGV1ciwgT3BlblFpYXJhIG5lIGxlIGNvbXB0
YW50IHBsdXMgZGFucyBzYSBzYW50ZSkgOyB2NiAyNy8xMCA6IGxpbWl0ZXMgaG9yYWlyZXMgc3Vy
IGwndXB0aW1lIGV0IG5vbgojIGwnaG9ybG9nZSBtdXJhbGUsIHZhbGV1cnMgaW52YWxpZGVzIGRl
IGd1YXJkLmNvbmYgcmFtZW5lZXMgYXUgZGVmYXV0LCBpbnN0YW50YW5lcyBkZSAxOTcwIGVsYWd1
ZXMsIHVzZS1wcmV2IGxpbWl0ZSA7CiMgdjUgMjcvMTAgOiBndWFyZC5jb25mIGx1IGV0IG5vbiBl
eGVjdXRlLCBhcnJldHMgdmVyaWZpZXMsIG9yZHJlcyBsaW1pdGVzIDsgdjQgOiBpbnN0YW50YW5l
cyBkJ2luY2lkZW50IDsgdjMgOiBib2l0ZSBub2lyZSwgZWNoYW50aWxsb25zIElWKS4KIyBJbCBv
YnNlcnZlIGV0LCBzZXVsZW1lbnQgc2kgbmVjZXNzYWlyZSwgYWdpdCBkYW5zIGwnb3JkcmUgbGUg
cGx1cyBkb3V4IDoKIyAgMS4gYXBwbGljYXRpb24gOiB2aXZhbnRlIChzaW5vbiBsYW5jZWUgYXUg
Ym91dCBkZSBERUFEX1NFQyksIHBhcyBmaWdlZSAoZmljaGllciBkZSBzYW50ZSksIG1lbW9pcmUg
ZGlzcG9uaWJsZSA7CiMgIDIuIGVzc2FpIGRlIG1pc2UgYSBqb3VyIDogdmFsaWRhdGlvbiBvdSBy
ZXRvdXIgYXJyaWVyZSA7CiMgIDMuIFNTSCAyMiBldCAyMjIyIGEgbCdlY291dGUgOyBwbGFjZSBz
dXIgL2RhdGEgOwojICA0LiByZXNlYXUgOiBwYXNzZXJlbGxlIGluam9pZ25hYmxlIC0+IHJlYXNz
b2NpYXRpb24gV2ktRmkgLT4gcmVjaGFyZ2VtZW50IGR1IHBpbG90ZSAtPiByZWRlbWFycmFnZSAo
bGltaXRlKSA7CiMgIDUuIG9yZHJlcyBkZSBIb21lIEFzc2lzdGFudCAoZmljaGllcnMgZGVwb3Nl
cyBwYXIgbCdhcHBsaWNhdGlvbiBkYW5zICRSVU4vY21kLykgOwojICA2LiBkaWFnbm9zdGljIDog
cmVnbGFnZXMgdmlkZW8gZWZmZWN0aWZzIGRlIGhsY2FtZCwgZXRhdCBlY3JpdCBkYW5zICRSVU4v
Z3VhcmQtc3RhdHVzIDsKIyAgNy4gKHY3KSB2aWRlbyA6IGhsY2FtZCBhYnNlbnQgZGVwdWlzIFZJ
REVPX0dPTkVfU0VDIC0+IHJlZGVtYXJyYWdlIGRlIGxhIGNhbWVyYSAoYnVkZ2V0IFJFQk9PVF9N
QVggc3VyIFJFQk9PVF9XSU5ET1cpLgojIEVjb25vbWllIDogdW5lIHNldWxlIGJvdWNsZSBzaGVs
bCA7IGxlY3R1cmVzIHBhciBidWlsdGlucyAocmVhZCwgY2FzZSkgOyBsZXMgY29udHJvbGVzIGNv
dXRldXggc29udCBlc3BhY2VzLgojIFRvdXRlcyBsZXMgZHVyZWVzIHNvbnQgbWVzdXJlZXMgc3Vy
IC9wcm9jL3VwdGltZS4gQ2hhcXVlIGFjdGlvbiBlc3Qgam91cm5hbGlzZWUgYXZlYyBzYSByYWlz
b24uCiMgUmVzZWF1ICh2OCwgZW5xdWV0ZSBkdSAyNy8xMC8yMDI2KSA6IGxhIHB1Y2UgV2ktRmkg
U1NWNjAyMCByZXBvbmQgZWxsZS1tZW1lIGF1eCBwaW5ncyBldCBhIGwnQVJQIChUVEwgMjU1KSwg
bWVtZSBxdWFuZCBsZQojIExpbnV4IGRlIGxhIGNhbWVyYSBuZSByZXBvbmQgcGx1cy4gTGUgc3Vy
dmVpbGxhbnQgbmUgZGVkdWl0IGRvbmMgSkFNQUlTIGwnZXRhdCBkdSByZXNlYXUgZCd1biBwaW5n
IHJlY3UgZGUgbCdleHRlcmlldXIgbmkgZCd1bgojIGNvbXB0ZXVyIElDTVAgOiBzZXVscyBzZXMg
cHJvcHJlcyBwaW5ncyBzb3J0YW50cyB2ZXJzIGxhIHBhc3NlcmVsbGUgKG5ldF9vaykgZm9udCBm
b2ksIGNvbW1lIGRlcHVpcyBsYSB2MS4KIyBTaGVsbCA6IC9iaW4vc2ggZGUgbGEgY2FtZXJhIGVz
dCBiYXNoIDUuMiAobGllbiBzaCAtPiBiYXNoKSA7IEJ1c3lCb3ggMS4zNiBmb3Vybml0IGFzaC4g
UmllbiBpY2kgbmUgZG9pdCBzdXBwb3NlciBsJ3VuIG91IGwnYXV0cmUuClFQX1dITz1xcC1ndWFy
ZApRUD0ke1FQOi0vZGF0YS9xcH0KIyBjb21tb24uc2ggLSBmb25jdGlvbnMgY29tbXVuZXMgZGUg
wqsgUWlhcmEgUGx1cyDCuyAoQ2xhdWRlLCAyNi8xMC8yMDI2LCB2MiA6IGVjb25vbWUgZW4gbWVt
b2lyZSBldCBlbiBwcm9jZXNzdXMgOwojIHY2IDI3LzEwLzIwMjYgOiBhZ2VzIG1lc3VyZXMgc3Vy
IGwndXB0aW1lIGV0IGxlIG51bWVybyBkZSBkZW1hcnJhZ2UsIGphbWFpcyBzdXIgbGEgc2V1bGUg
aG9ybG9nZSBtdXJhbGUpCiMgU2hlbGwgOiBidXN5Ym94IGFzaCBkZSBsYSBjYW1lcmEuIFJpZW4g
aWNpIG5lIGRvaXQgc3VwcG9zZXIgYmFzaC4KIyBMZXMgZHVyZWVzIHNlIG1lc3VyZW50IHN1ciAv
cHJvYy91cHRpbWUgKG1vbm90b25lKSA6IGwnaG9ybG9nZSBtdXJhbGUgZGVtYXJyZSBlbiAxOTcw
IGV0IHNhdXRlIGF1IHJlZ2xhZ2UgTlRQLgpRUD0ke1FQOi0vZGF0YS9xcH0gICAgICAgICAgICAg
ICAgICMgcGV0aXQgOiBldGF0LCBiaW5haXJlIGQnb3JpZ2luZSAoY2FydGUgL2RhdGEsIDIwIE1p
bykKQlVMSz0ke1FQX0JVTEs6LS9tZWRpYS9xcH0gICAgICAgICAjIGdyb3MgOiBlbXBsYWNlbWVu
dHMgZ29vZCBldCBuZXcgKGNhcnRlIC9tZWRpYSwgMiw4IEdvKQpSVU49JHtRUF9SVU46LS90bXAv
cXB9ICAgICAgICAgICAgICMgbWVtb2lyZSB2aXZlIDogc2FudGUsIG9yZHJlcywgZXRhdCBkZXMg
ZXNzYWlzClNUPSRRUC9zdGF0ZQpMT0c9JHtRUF9MT0c6LS9kYXRhL29wZW5xaWFyYWQubG9nfQpP
TEQ9JHtRUF9PTEQ6LS9tZWRpYS9vcGVucWlhcmFkLm9sZH0gICAjIHJlcGxpIHVsdGltZSBkdSBs
YW5jZXVyIChldCBkZSBwb3N0X2Jvb3Quc2ggc2kgL2RhdGEvb3BlbnFpYXJhZCBkaXNwYXJhaXQp
IDsgdjYgOiByYWZyYWljaGkgcGFyIHByb21vdGUvc2VlZC1nb29kLCBlbXByZWludGUgYSBjb3Rl
ClsgLWQgIiRTVCIgXSAmJiBbIC1kICIkUlVOIiBdIHx8IG1rZGlyIC1wICIkU1QiICIkUlVOIiAy
Pi9kZXYvbnVsbAoKdHMoKSB7IGRhdGUgJyslWS0lbS0lZFQlSDolTTolUyc7IH0Kbm93KCkgeyBk
YXRlICslczsgfQpsb2coKSB7IGVjaG8gIlske1FQX1dITzotcXB9XSAkKHRzKSAkKiIgPj4gIiRM
T0ciIDI+L2Rldi9udWxsOyB9CiMgbGVjdHVyZSBkJ3VuZSBsaWduZSBzYW5zIHByb2Nlc3N1cyBz
dXBwbGVtZW50YWlyZSA6IHJkIFZBUiBmaWNoaWVyIFtkZWZhdXRdCnJkKCkgeyBldmFsICIkMT0i
IDsgWyAtcyAiJDIiIF0gJiYgeyByZWFkIC1yICIkMSIgPCAiJDIiIHx8IDo7IH07IGV2YWwgIlsg
LW4gXCJcJCQxXCIgXSB8fCAkMT1cJHszLX0iOyB9CnVwX25vdygpIHsgX3VwdD0wOyByZWFkIC1y
IF91cHQgX3VwciA8ICIke1FQX1VQVElNRTotL3Byb2MvdXB0aW1lfSIgMj4vZGV2L251bGw7IFVQ
PSR7X3VwdCUlLip9OyBjYXNlICIkVVAiIGluICcnfCpbITAtOV0qKSBVUD0wOzsgZXNhYzsgfSAg
ICMgbWV0IGEgam91ciAkVVAgKHNlY29uZGVzIGRlcHVpcyBsZSBkZW1hcnJhZ2UgOyBRUF9VUFRJ
TUUgOiBiYW5jIGQnZXNzYWkpCmJvb3RfaWQoKSB7IGlmIFsgLW4gIiRRUF9CT09UX0lEIiBdOyB0
aGVuIEJPT1Q9JFFQX0JPT1RfSUQ7IGVsc2UgcmVhZCAtciBCT09UIDwgL3Byb2Mvc3lzL2tlcm5l
bC9yYW5kb20vYm9vdF9pZDsgZmk7IH0KIyB2NiA6IG51bWVybyBkZSBkZW1hcnJhZ2UuICRTVC9i
b290X3NlcSA9ICJib290X2lkIG51bWVybyIgOyBsZSBsYW5jZXVyIGwnaW5jcmVtZW50ZSBhIGNo
YXF1ZSBub3V2ZWF1IGRlbWFycmFnZSAoYm9vdF9zZXFfYnVtcCksCiMgbGVzIGF1dHJlcyBsZSBs
aXNlbnQgKGJvb3Rfc2VxX25vdyBwb3NlIFNFUSwgZW4gY29tcHRhbnQgMSBkZSBwbHVzIHNpIGxl
IGZpY2hpZXIgdmllbnQgZCd1biBhdXRyZSBkZW1hcnJhZ2UpLiBJbCBwZXJtZXQgZGUKIyBmYWly
ZSBleHBpcmVyLCBhcHJlcyB1biBub21icmUgZGUgZGVtYXJyYWdlcywgY2UgcXVpIGEgZXRlIGRh
dGUgYSBsJ2hvcmxvZ2UgZGUgMTk3MCAoc2FucyByZXNlYXUsIGwnaGV1cmUgbidlc3QgcGFzIGZp
YWJsZSkuCmJvb3Rfc2VxX25vdygpIHsgYm9vdF9pZDsgX3NiPTsgX3NzPTA7IFsgLXMgIiRTVC9i
b290X3NlcSIgXSAmJiByZWFkIC1yIF9zYiBfc3MgPCAiJFNUL2Jvb3Rfc2VxIiAyPi9kZXYvbnVs
bDsgdG9pbnQgX3NzIDA7IFNFUT0kX3NzOyBbICIkX3NiIiA9ICIkQk9PVCIgXSB8fCBTRVE9JCgo
X3NzICsgMSkpOyB9CmJvb3Rfc2VxX2J1bXAoKSB7IGJvb3Rfc2VxX25vdzsgWyAiJF9zYiIgPSAi
JEJPT1QiIF0gfHwgcHV0ICIkU1QvYm9vdF9zZXEiICIkQk9PVCAkU0VRIjsgfQojIEVudGllcnMg
c3VycyBwb3VyICQoKCApKSA6IGVuIG1vZGUgUE9TSVgsIHVuZSBlcnJldXIgYXJpdGhtZXRpcXVl
ICgiMTJ4Iiwgb3UgIjA4IiBsdSBlbiBvY3RhbCkgQVJSRVRFIGxlIHNoZWxsLgojIFNldWxzIGxl
cyBjaGlmZnJlcyBzb250IGFjY2VwdGVzIDsgbGVzIHplcm9zIGRlIHRldGUgc29udCByZXRpcmVz
LgppbnQoKSB7IGNhc2UgIiQxIiBpbiAnJ3wqWyEwLTldKikgZWNobyAiJHsyOi0wfSI7OyAqKSBf
aT0kezEjIiR7MSUlWyEwXSp9In07IGVjaG8gIiR7X2k6LTB9Ijs7IGVzYWM7IH0KdG9pbnQoKSB7
IGV2YWwgImNhc2UgXCJcJCQxXCIgaW4gJyd8KlshMC05XSopICQxPVwkezI6LTB9OzsgKikgJDE9
XCR7JDEjXCJcJHskMSUlWyEwXSp9XCJ9OyAkMT1cJHskMTotMH07OyBlc2FjIjsgfSAgICAjIHRv
aW50IFZBUiBbZGVmYXV0XSA6IHNhbnMgcHJvY2Vzc3VzCgojIEVjcml0dXJlIGF0b21pcXVlIDog
ZmljaGllciB0ZW1wb3JhaXJlIGR1IG1lbWUgZG9zc2llciwgcHVpcyByZW5vbW1hZ2UuCnB1dCgp
IHsgZWNobyAiJDIiID4gIiQxLnRtcC4kJCIgMj4vZGV2L251bGwgJiYgbXYgLWYgIiQxLnRtcC4k
JCIgIiQxIiAyPi9kZXYvbnVsbDsgfQpnZXQoKSB7IGlmIFsgLXMgIiQxIiBdOyB0aGVuIGhlYWQg
LW4xICIkMSI7IGVsc2UgZWNobyAiJDIiOyBmaTsgfQojIFJlc3VsdGF0IGRlIGxhIGRlcm5pZXJl
IG1pc2UgYSBqb3VyIDogZW4gbWVtb2lyZSB2aXZlIChsdSBwYXIgbGVzIGFuY2llbm5lcyB2ZXJz
aW9ucyBkJ09wZW5RaWFyYSkgRVQgc3VyIGxhIGNhcnRlCiMgKGlsIHN1cnZpdCBhIHVuIHJlZGVt
YXJyYWdlKS4gRWNyaXQgc2V1bGVtZW50IGxvcnMgZCd1bmUgbWlzZSBhIGpvdXIgb3UgZCd1biBy
ZXRvdXIgOiB1c3VyZSBuZWdsaWdlYWJsZS4KcmVzdWx0KCkgeyBwdXQgIiRSVU4vbGFzdF91cGRh
dGVfcmVzdWx0IiAiJDEiOyBwdXQgIiRTVC9sYXN0X3VwZGF0ZV9yZXN1bHQiICIkMSI7IH0KbGFz
dF9yZXN1bHQoKSB7IHJkIF9sciAiJFJVTi9sYXN0X3VwZGF0ZV9yZXN1bHQiICIiOyBbIC1uICIk
X2xyIiBdIHx8IHJkIF9sciAiJFNUL2xhc3RfdXBkYXRlX3Jlc3VsdCIgYXVjdW47IH0Kc2hhX29m
KCkgeyBzaGEyNTZzdW0gIiQxIiAyPi9kZXYvbnVsbCB8IGN1dCAtZCcgJyAtZjE7IH0KIyB2NSA6
IGwnYXBwbGljYXRpb24gbGFuY2VlIHBhciBsZSBsYW5jZXVyLiBsaXZlX2NoaWxkIHBvc2UgQ0gg
YSBzb24gbnVtZXJvIGRlIHByb2Nlc3N1cywgc2V1bGVtZW50IHNpIGNlIG51bWVybyB2aXQgRVQg
cG9ydGUgbGUKIyBub20gZGUgbCdhcHBsaWNhdGlvbiAob3BlbnFpYXJhZCwgb3Ugb3BlbnFpYXJh
ZC5vbGQgZW4gcmVwbGkgdWx0aW1lKSA6ICRTVC9jaGlsZCBlc3Qgc3VyIGxhIGNhcnRlLCBpbCBz
dXJ2aXQgYSB1biByZWRlbWFycmFnZSwKIyBldCBsZSBudW1lcm8gcGV1dCBhdm9pciBldGUgcmVw
cmlzIHBhciB1biBhdXRyZSBwcm9ncmFtbWUgKGRyb3BiZWFyLCBobGNhbWQuLi4pIHF1J3VuIGFy
cmV0IG5lIGRvaXQgamFtYWlzIHRvdWNoZXIuCkFQUF9DT01NPSR7UVBfQVBQX0NPTU06LW9wZW5x
aWFyYWR9CmxpdmVfY2hpbGQoKSB7CiAgcmQgQ0ggIiRTVC9jaGlsZCIgMDsgdG9pbnQgQ0ggMAog
IFsgIiRDSCIgIT0gMCBdICYmIGtpbGwgLTAgIiRDSCIgMj4vZGV2L251bGwgfHwgeyBDSD0wOyBy
ZXR1cm4gMTsgfQogIF9jPTsgcmVhZCAtciBfYyA8IC9wcm9jLyRDSC9jb21tIDI+L2Rldi9udWxs
CiAgY2FzZSAiJF9jIiBpbiAiJEFQUF9DT01NInwiJEFQUF9DT01NIi4qKSByZXR1cm4gMDs7IGVz
YWMKICBDSD0wOyByZXR1cm4gMQp9CgojIERvc3NpZXIgZCd1biBlbXBsYWNlbWVudCA6IGZhY3Rv
cnkgc3VyIC9kYXRhICh0b3Vqb3VycyBwcmVzZW50KSwgZ29vZCBldCBuZXcgc3VyIC9tZWRpYS4K
c2QoKSB7IGNhc2UgIiQxIiBpbiBmYWN0b3J5KSBlY2hvICIkUVAvc2xvdHMvZmFjdG9yeSI7OyAq
KSBlY2hvICIkQlVMSy9zbG90cy8kMSI7OyBlc2FjOyB9CiMgT3JkcmUgZGUgcmVwbGkgOiBuZXcg
LT4gZ29vZCAtPiBwcmV2IChsYSB2ZXJzaW9uIHZhbGlkZWUgYXZhbnQgZ29vZCkgLT4gZmFjdG9y
eSAob3JpZ2luZSwgc3VyIC9kYXRhKQpvcmRlcigpIHsgY2FzZSAiJDEiIGluIG5ldykgZWNobyAi
bmV3IGdvb2QgcHJldiBmYWN0b3J5Ijs7IGdvb2QpIGVjaG8gImdvb2QgcHJldiBmYWN0b3J5Ijs7
IHByZXYpIGVjaG8gInByZXYgZmFjdG9yeSI7OyAqKSBlY2hvICJmYWN0b3J5Ijs7IGVzYWM7IH0K
CiMgQWdlIGQndW4gZXZlbmVtZW50IGRhdGUgImJvb3RfaWQgdXB0aW1lIGhvcmxvZ2UiIDogYWdl
X29mIEIgVSBXIHBvc2UgQUdFIChzZWNvbmRlcyksIG1lc3VyZSBzdXIgbCd1cHRpbWUgc2kgbWVt
ZSBkZW1hcnJhZ2UsCiMgc3VyIGwnaG9ybG9nZSBtdXJhbGUgc2lub24gZXQgc2V1bGVtZW50IHNp
IGVsbGUgZXN0IHBsYXVzaWJsZSBkZXMgZGV1eCBjb3RlcyAoYXByZXMgMjAyMy0xMSwgY3JvaXNz
YW50ZSkgOyBBR0U9LTEgc2kgaW5jb25udQojIChhdXRyZSBkZW1hcnJhZ2UsIGhvcmxvZ2UgZGUg
MTk3MCBkJ3VuIGNvdGUpLiBVbiBXIHNldWwgKGFuY2llbiBmb3JtYXQsIG51bWVyaXF1ZSkgdmF1
dCAiYXV0cmUgZGVtYXJyYWdlIi4KYWdlX29mKCkgewogIF9hYj0kMTsgX2F1PSQyOyBfYXc9JDM7
IEFHRT0tMQogIGJvb3RfaWQ7IHVwX25vdwogIGlmIFsgLW4gIiRfYWIiIF0gJiYgWyAiJF9hYiIg
PSAiJEJPT1QiIF07IHRoZW4gQUdFPSQoKCBVUCAtICQoaW50ICIkX2F1IiAwKSApKTsgWyAiJEFH
RSIgLWx0IDAgXSAmJiBBR0U9MDsgcmV0dXJuIDA7IGZpCiAgX2FuPSQobm93KTsgX2F3PSQoaW50
ICIkX2F3IiAwKQogIGlmIFsgIiRfYW4iIC1ndCAxNzAwMDAwMDAwIF0gJiYgWyAiJF9hdyIgLWd0
IDE3MDAwMDAwMDAgXSAmJiBbICIkX2FuIiAtZ2UgIiRfYXciIF07IHRoZW4gQUdFPSQoKF9hbiAt
IF9hdykpOyBmaQp9CiMgTWFycXVhZ2UgQkFEIDogImJvb3RfaWQgdXB0aW1lIGhvcmxvZ2UgbnVt
ZXJvX2RlX2RlbWFycmFnZSIuIElsIGV4cGlyZSBhcHJlcyBRUF9CQURfVFRMIHMgKG1lc3VyZSBz
dXIgdXB0aW1lIHNpIG1lbWUKIyBkZW1hcnJhZ2UsIHN1ciBsJ2hvcmxvZ2Ugc2lub24gZXQgc2V1
bGVtZW50IHNpIGVsbGUgZXN0IHBsYXVzaWJsZSkgb3UsIHF1YW5kIGwnYWdlIGVzdCBpbmNvbm51
IChwb3NlIGEgbCdob3Jsb2dlIGRlIDE5NzAsCiMgcHVpcyByZWRlbWFycmFnZSksIGFwcmVzIFFQ
X0JBRF9CT09UUyBkZW1hcnJhZ2VzICh2NiA6IHNhbnMgY2VsYSB1biBlbXBsYWNlbWVudCBlY2Fy
dGUgYXZhbnQgbGUgcmVnbGFnZSBkZSBsJ2hldXJlIGwnZXRhaXQKIyBwb3VyIHRvdWpvdXJzKS4g
RW4gY2FzIGRlIGRvdXRlLCBsJ2VtcGxhY2VtZW50IHJlc3RlIGVjYXJ0ZS4KQkFEX1RUTD0ke1FQ
X0JBRF9UVEw6LTE4MDB9CkJBRF9CT09UUz0ke1FQX0JBRF9CT09UUzotMn0Kc2xvdF9iYWQoKSB7
CiAgX2Y9JChzZCAiJDEiKS9CQUQKICBbIC1lICIkX2YiIF0gfHwgcmV0dXJuIDEKICBbICIkMSIg
PSBmYWN0b3J5IF0gJiYgcmV0dXJuIDEgICAgICAgIyBsZSBiaW5haXJlIGQnb3JpZ2luZSBuJ2Vz
dCBqYW1haXMgZWNhcnRlCiAgX2I9OyBfdT07IF93PTsgX3E9OyByZWFkIC1yIF9iIF91IF93IF9x
IDwgIiRfZiIgMj4vZGV2L251bGwKICBbIC16ICIkX3UiIF0gJiYgWyAteiAiJF93IiBdICYmIHsg
X3c9JF9iOyBfYj07IH0gICAgICAgICMgYW5jaWVuIGZvcm1hdCA6IHVuZSBzZXVsZSBkYXRlCiAg
IyB2NiA6IHVuIG1hcnF1YWdlIHZpZGUgb3UgaWxsaXNpYmxlIChmaWNoaWVyIHRyb25xdWUpIG5l
IHZhdXQgcmllbiA6IGlsIGVzdCByZXRpcmUuIFVuZSBib3VjbGUgZCdhcnJldHMgbGUgcmVwb3Nl
cmFpdAogICMgY29ycmVjdGVtZW50IGVuIHF1ZWxxdWVzIHNlY29uZGVzIDsgbGUgZ2FyZGVyIGF1
cmFpdCBlY2FydGUgbCdlbXBsYWNlbWVudCBwb3VyIHRvdWpvdXJzLgogIGNhc2UgIiR7X3U6LTB9
JHtfdzotMH0iIGluICpbITAtOV0qKSBybSAtZiAiJF9mIjsgbG9nICJtYXJxdWFnZSBCQUQgZGUg
JDEgaWxsaXNpYmxlIDogcmV0aXJlIjsgcmV0dXJuIDE7OyBlc2FjCiAgWyAtbiAiJF91JF93IiBd
IHx8IHsgcm0gLWYgIiRfZiI7IGxvZyAibWFycXVhZ2UgQkFEIGRlICQxIHZpZGUgOiByZXRpcmUi
OyByZXR1cm4gMTsgfQogIGFnZV9vZiAiJF9iIiAiJF91IiAiJF93IgogIGlmIFsgIiRBR0UiIC1s
dCAwIF07IHRoZW4KICAgIF9hZ2U9MAogICAgY2FzZSAiJF9xIiBpbiAnJ3wqWyEwLTldKikgOzsg
KikgYm9vdF9zZXFfbm93OyBbICQoKFNFUSAtICQoaW50ICIkX3EiIDApKSkgLWdlICIkQkFEX0JP
T1RTIiBdICYmIF9hZ2U9JEJBRF9UVEw7OyBlc2FjCiAgZWxzZSBfYWdlPSRBR0U7IGZpCiAgWyAi
JF9hZ2UiIC1sdCAiJEJBRF9UVEwiIF0gJiYgcmV0dXJuIDAKICBybSAtZiAiJF9mIjsgcmV0dXJu
IDEKfQojIEVtcGxhY2VtZW50IHV0aWxpc2FibGUgOiBiaW5haXJlIG5vbiB2aWRlLCBub24gQkFE
LCBlbXByZWludGUgY29uZm9ybWUgKGV4aWdlZSBwb3VyIGdvb2QgZXQgbmV3KS4gUG9zZSAkVlNI
QS4Kc2xvdF92YWxpZCgpIHsKICBfZD0kKHNkICIkMSIpOyBWU0hBPQogIFsgLXMgIiRfZC9vcGVu
cWlhcmFkIiBdIHx8IHJldHVybiAxCiAgc2xvdF9iYWQgIiQxIiAmJiByZXR1cm4gMQogIGlmIFsg
LXMgIiRfZC9vcGVucWlhcmFkLnNoYTI1NiIgXTsgdGhlbgogICAgX3dhbnQ9OyByZWFkIC1yIF93
YW50IF94IDwgIiRfZC9vcGVucWlhcmFkLnNoYTI1NiIKICAgIFZTSEE9JChzaGFfb2YgIiRfZC9v
cGVucWlhcmFkIikKICAgIFsgIiRfd2FudCIgPSAiJFZTSEEiIF0gfHwgcmV0dXJuIDEKICBlbHNl
CiAgICBbICIkMSIgPSBmYWN0b3J5IF0gfHwgcmV0dXJuIDEKICBmaQogIHJldHVybiAwCn0KbWFy
a19iYWQoKSB7IFsgIiQxIiA9IGZhY3RvcnkgXSAmJiByZXR1cm4gMDsgYm9vdF9zZXFfbm93OyB1
cF9ub3c7IHB1dCAiJChzZCAiJDEiKS9CQUQiICIkQk9PVCAkVVAgJChub3cpICRTRVEiOyBsb2cg
ImVtcGxhY2VtZW50ICQxIG1hcnF1ZSBCQUQiOyB9CkNPTkY9JFFQL2d1YXJkLmNvbmYKIyAtLS0g
cmVnbGFnZXMgcGFyIGRlZmF1dCAobW9kaWZpYWJsZXMgZGFucyBndWFyZC5jb25mLCBsaWduZXMg
Tk9NPXZhbGV1cikgLS0tClRJQ0s9MTAgICAgICAgICAgICAgICAgICMgcGVyaW9kZSBkZSBsYSBi
b3VjbGUgKHMpClNMT1dfU0VDPTYwICAgICAgICAgICAgICMgY29udHJvbGVzIGVzcGFjZXMgOiBT
U0gsIHBsYWNlIGRpc3F1ZSwgcmVnbGFnZXMgdmlkZW8sIGV0YXQKSEVBTFRIX0dSQUNFPTMwMCAg
ICAgICAgIyBkZWxhaSBhcHJlcyBsZSBsYW5jZW1lbnQgYXZhbnQgZGUganVnZXIgbGEgc2FudGUg
KHMpCkhFQUxUSF9TVEFMRT0xODAgICAgICAgICMgc2FudGUgcGx1cyB2aWVpbGxlIHF1ZSBjZWxh
ID0gYXBwbGljYXRpb24gZmlnZWUgKHMpClBST01PVEVfQUZURVI9MTgwICAgICAgICMgZm9uY3Rp
b25uZW1lbnQgc2FpbiBhdmFudCBkZSB2YWxpZGVyIHVuIGVzc2FpIChzKQpUUklBTF9IQU5HX01B
WD0yICAgICAgICAjIGJsb2NhZ2VzIHBlbmRhbnQgdW4gZXNzYWkgYXZhbnQgcmV0b3VyIGFycmll
cmUKTUVNX01JTl9LQj05MDAwICAgICAgICAgIyBNZW1BdmFpbGFibGUgc291cyBjZSBzZXVpbC4u
LgpNRU1fTE9XX1NFQz0zMDAgICAgICAgICAjIC4uLnBlbmRhbnQgY2V0dGUgZHVyZWUgPSByZWxh
bmNlIGRlIGwnYXBwbGljYXRpb24gKDIgZm9pcyBwYXIgaGV1cmUgYXUgcGx1cykKTkVUX0NIRUNL
X1NFQz0zMCAgICAgICAgIyBwaW5nIGRlIGxhIHBhc3NlcmVsbGUgKHRvdXRlcyBsZXMgVElDSyBz
IHF1YW5kIGVsbGUgbmUgcmVwb25kIHBsdXMpCk5FVF9MMV9TRUM9OTAgICAgICAgICAgICMgcGFz
c2VyZWxsZSBtdWV0dGUgZGVwdWlzIDogcmVhc3NvY2lhdGlvbiBXaS1GaQpORVRfTDJfU0VDPTMw
MCAgICAgICAgICAjICAgICAgICAgICAgICAgICAgICAgICAgICAgIHJlY2hhcmdlbWVudCBkdSBw
aWxvdGUgV2ktRmkKTkVUX0wzX1NFQz05MDAgICAgICAgICAgIyAgICAgICAgICAgICAgICAgICAg
ICAgICAgICByZWRlbWFycmFnZSBkZSBsYSBjYW1lcmEKSU5DSURFTlRfTUlOX1NFQz02MCAgICAg
IyAodjQpIGNvdXB1cmUgYXUgbW9pbnMgYXVzc2kgbG9uZ3VlIDogaW5zdGFudGFuZSBkJ2luY2lk
ZW50IGEgc29uIHJldG91cgpNUVRUX1JFU1RBUlRfU0VDPTkwMCAgICAjIE1RVFQgY291cGUgYWxv
cnMgcXVlIGxlIHNlcnZldXIgTVFUVCByZXBvbmQgOiByZWxhbmNlIGRlIGwnYXBwbGljYXRpb24g
KDIgZm9pcyBwYXIgaGV1cmUgYXUgcGx1cykKSEFOR19NQVhfSE9VUj0zICAgICAgICAgIyBhcnJl
dHMgcG91ciBibG9jYWdlIGhvcnMgZXNzYWkgOiBhdSBwbHVzIDMgcGFyIGhldXJlIChhdS1kZWxh
IDogam91cm5hbGlzZSBzZXVsZW1lbnQpCkRFQURfU0VDPTEyMCAgICAgICAgICAgICMgYXBwbGlj
YXRpb24gYWJzZW50ZSBkZXB1aXMgOiBsZSBzdXJ2ZWlsbGFudCBsYSBsYW5jZSBsdWktbWVtZQpS
RUJPT1RfTUFYPTMgICAgICAgICAgICAjIHJlZGVtYXJyYWdlcyBhdXRvbWF0aXF1ZXMgYXUgcGx1
cy4uLgpSRUJPT1RfV0lORE9XPTIxNjAwICAgICAjIC4uLnN1ciBjZXR0ZSBkdXJlZSAocykKT1JE
RVJfUkVCT09UX01BWD0wICAgICAgIyAodjYpIHJlZGVtYXJyYWdlcyBzdXIgb3JkcmUgZGUgSG9t
ZSBBc3Npc3RhbnQsIGJ1ZGdldCBzZXBhcmUsIHN1ciBsYSBtZW1lIGR1cmVlIDsgdjEwIDogMCA9
IHNhbnMgbGltaXRlIChkZWZhdXQpClZJREVPX0dPTkVfU0VDPTYwMCAgICAgICMgKHY3KSBobGNh
bWQgYWJzZW50IGRlcHVpcyA6IHJlZGVtYXJyYWdlIGRlIGxhIGNhbWVyYSAoYnVkZ2V0IFJFQk9P
VF9NQVgpIDsgMCA9IGphbWFpcwpTU0hfU0VDT1VSU19QT1JUPTAgICAgICAjIHNlY29uZCBTU0gg
ZGUgc2Vjb3VycyBsYW5jZSBwYXIgbGUgc3VydmVpbGxhbnQgKGRyb3BiZWFyIHN1ciBjZSBwb3J0
LCBjbGUgc2V1bGVtZW50KSA7IDAgPSBhdWN1bgpFTkFCTEVfV0lGSV9BQ1RJT05TPTEKRU5BQkxF
X1JFQk9PVD0xCiMgKHY3KSBwYXMgZGUgY2hpZW4gZGUgZ2FyZGUgbWF0ZXJpZWwgZHUgcHJvY2Vz
c2V1ciBpY2kgOiBsZSBtaWNyb2NvbnRyb2xldXIgcmFkaW8gZW4gYSBkZWphIHVuLCBub3Vycmkg
cGFyIE9wZW5RaWFyYQojIHRhbnQgcXUnaWwgZXN0IHNhaW4gOyBFTkFCTEVfU09DX1dEVCBkJ3Vu
IGFuY2llbiBndWFyZC5jb25mIGVzdCBpZ25vcmUuClBBU1NJVkU9MCAgICAgICAgICAgICAgICMg
MSA9IG9ic2VydmUgZXQgam91cm5hbGlzZSBzZXVsZW1lbnQsIGF1Y3VuZSBhY3Rpb24gKGVzc2Fp
cyBhIGJsYW5jIHN1ciBsYSBjYW1lcmEpCkdBVEVXQVk9CkRST1BCRUFSPSR7UVBfRFJPUEJFQVI6
LS91c3Ivc2Jpbi9kcm9wYmVhcn0KU1lTUlE9JHtRUF9TWVNSUTotL3Byb2Mvc3lzcnEtdHJpZ2dl
cn0KTEFVTkNIRVI9JHtRUF9MQVVOQ0hFUjotL2RhdGEvb3BlbnFpYXJhZH0KTkVUX1RDUD0ke1FQ
X05FVF9UQ1A6LS9wcm9jL25ldC90Y3B9CiMgdjUgOiBndWFyZC5jb25mIGVzdCBMVSBsaWduZSBh
IGxpZ25lIChOT009dmFsZXVyKSwgamFtYWlzIGV4ZWN1dGUgOiB1bmUgbGlnbmUgYWJpbWVlIHBh
ciBsYSBjYXJ0ZSBTRCBuZSBkb2l0IHBhcyBhcnJldGVyIGxlCiMgc3VydmVpbGxhbnQgYXUgZGVt
YXJyYWdlICh1bmUgZXJyZXVyIGRlIHN5bnRheGUgZGFucyB1biBmaWNoaWVyIMKrIHNvdXJjZSDC
uyB0ZXJtaW5lIHVuIHNoZWxsIG5vbiBpbnRlcmFjdGlmKSwgZXQgbGUgZmljaGllcgojIG5lIGRv
aXQgcGFzIHBvdXZvaXIgbGFuY2VyIGRlIGNvbW1hbmRlLiBTZXVscyBsZXMgbm9tcyBjaS1kZXNz
b3VzIHNvbnQgYWNjZXB0ZXMsIGF2ZWMgZGVzIHZhbGV1cnMgc2ltcGxlcy4KTlVNUz0iVElDSyBT
TE9XX1NFQyBIRUFMVEhfR1JBQ0UgSEVBTFRIX1NUQUxFIFBST01PVEVfQUZURVIgVFJJQUxfSEFO
R19NQVggTUVNX01JTl9LQiBNRU1fTE9XX1NFQyBORVRfQ0hFQ0tfU0VDIE5FVF9MMV9TRUMgTkVU
X0wyX1NFQyBORVRfTDNfU0VDIElOQ0lERU5UX01JTl9TRUMgTVFUVF9SRVNUQVJUX1NFQyBIQU5H
X01BWF9IT1VSIERFQURfU0VDIFJFQk9PVF9NQVggUkVCT09UX1dJTkRPVyBPUkRFUl9SRUJPT1Rf
TUFYIFZJREVPX0dPTkVfU0VDIFNTSF9TRUNPVVJTX1BPUlQiCmZvciB2IGluICROVU1TOyBkbyBl
dmFsICJEXyR2PVwkJHYiOyBkb25lICAgICAgIyB2NiA6IGRlZmF1dHMgY29uc2VydmVzLCByZXBy
aXMgcXVhbmQgbGEgdmFsZXVyIGR1IGZpY2hpZXIgbidlc3QgcGFzIHVuIGVudGllcgppZiBbIC1m
ICIkQ09ORiIgXTsgdGhlbgogIHdoaWxlIElGUz0nPScgcmVhZCAtciBfayBfdjsgZG8KICAgIGNh
c2UgIiRfayIgaW4gJyd8JyMnKikgY29udGludWU7OyBlc2FjCiAgICBfdj0ke192I1wifTsgX3Y9
JHtfdiVcIn07IF92PSR7X3YjXCd9OyBfdj0ke192JVwnfQogICAgY2FzZSAiJF92IiBpbiAqWyFB
LVphLXowLTkuXzotXSopIGxvZyAiZ3VhcmQuY29uZiA6IHZhbGV1ciByZWZ1c2VlIHBvdXIgJChl
Y2hvICIkX2siIHwgY3V0IC1jMS0zMCkiOyBjb250aW51ZTs7IGVzYWMKICAgIGNhc2UgIiRfayIg
aW4KICAgICAgVElDS3xTTE9XX1NFQ3xIRUFMVEhfR1JBQ0V8SEVBTFRIX1NUQUxFfFBST01PVEVf
QUZURVJ8VFJJQUxfSEFOR19NQVh8TUVNX01JTl9LQnxNRU1fTE9XX1NFQ3xORVRfQ0hFQ0tfU0VD
fE5FVF9MMV9TRUN8TkVUX0wyX1NFQ3xORVRfTDNfU0VDfElOQ0lERU5UX01JTl9TRUN8TVFUVF9S
RVNUQVJUX1NFQ3xIQU5HX01BWF9IT1VSfERFQURfU0VDfFJFQk9PVF9NQVh8UkVCT09UX1dJTkRP
V3xPUkRFUl9SRUJPT1RfTUFYfFZJREVPX0dPTkVfU0VDfFNTSF9TRUNPVVJTX1BPUlR8RU5BQkxF
X1dJRklfQUNUSU9OU3xFTkFCTEVfUkVCT09UfFBBU1NJVkV8R0FURVdBWSkKICAgICAgICBldmFs
ICIkX2s9XCRfdiIgOzsKICAgICAgRU5BQkxFX1NPQ19XRFQpIDs7CiAgICAgICopIGxvZyAiZ3Vh
cmQuY29uZiA6IGxpZ25lIGlnbm9yZWUgKCQoZWNobyAiJF9rIiB8IGN1dCAtYzEtMzApKSIgOzsK
ICAgIGVzYWMKICBkb25lIDwgIiRDT05GIgpmaQojIHY2IDogdW5lIHZhbGV1ciBub24gbnVtZXJp
cXVlIChmaWNoaWVyIGFiaW1lLCBmYXV0ZSBkZSBmcmFwcGUpIHZhbGFpdCAxIDogUkVCT09UX1dJ
TkRPVz0xIGxldmFpdCBsZSBwbGFmb25kIGRlcyByZWRlbWFycmFnZXMsCiMgSEVBTFRIX1NUQUxF
PTEgYXJyZXRhaXQgbCdhcHBsaWNhdGlvbiBzYW5zIGNlc3NlLiBFbGxlIHJlcHJlbmQgbWFpbnRl
bmFudCBsZSBkZWZhdXQsIGV0IGxhIGxpZ25lIGVzdCBqb3VybmFsaXNlZS4KZm9yIHYgaW4gJE5V
TVM7IGRvCiAgZXZhbCAiX2N1cj1cJCR2OyBfZGVmPVwkRF8kdiIKICBjYXNlICIkX2N1ciIgaW4K
ICAgICcnfCpbITAtOV0qKSBsb2cgImd1YXJkLmNvbmYgOiAkdj0kKGVjaG8gIiRfY3VyIiB8IGN1
dCAtYzEtMjApIGludmFsaWRlLCBkZWZhdXQgJF9kZWYgY29uc2VydmUiOyBldmFsICIkdj1cJF9k
ZWYiIDs7CiAgICAqKSBldmFsICIkdj1cJChpbnQgXCJcJF9jdXJcIiBcIlwkX2RlZlwiKSIgOzsK
ICBlc2FjCmRvbmUKWyAiJFRJQ0siIC1nZSAxIF0gfHwgVElDSz0xClsgIiRTU0hfU0VDT1VSU19Q
T1JUIiAtbGUgNjU1MzUgXSB8fCB7IGxvZyAiZ3VhcmQuY29uZiA6IFNTSF9TRUNPVVJTX1BPUlQ9
JFNTSF9TRUNPVVJTX1BPUlQgaW52YWxpZGUsIGF1Y3VuIFNTSCBkZSBzZWNvdXJzIjsgU1NIX1NF
Q09VUlNfUE9SVD0wOyB9CiMgR0FURVdBWSA6IGFkcmVzc2UgSVB2NCBlbiBjaGlmZnJlcyBldCBw
b2ludHMsIHNpbm9uIGlnbm9yZWUgKHVuZSB2YWxldXIgZmF1c3NlIHJlbmRyYWl0IGxhIHBhc3Nl
cmVsbGUgwqsgbXVldHRlIMK7IGEgamFtYWlzIDoKIyByZWFzc29jaWF0aW9uLCByZWNoYXJnZW1l
bnQgZHUgcGlsb3RlIHB1aXMgcmVkZW1hcnJhZ2VzLCAzIHBhciA2IGgsIHNhbnMgZmluKQpjYXNl
ICIkR0FURVdBWSIgaW4KICAnJykgOzsKICAqWyEwLTkuXSp8Lip8Ki58Ki4uKikgbG9nICJndWFy
ZC5jb25mIDogR0FURVdBWT0kKGVjaG8gIiRHQVRFV0FZIiB8IGN1dCAtYzEtMjApIGludmFsaWRl
LCBwYXNzZXJlbGxlIGx1ZSBkYW5zIGxhIHRhYmxlIGRlIHJvdXRhZ2UiOyBHQVRFV0FZPSA7Owog
ICopIF9vPTA7IF9pZnM9JElGUzsgSUZTPS47IGZvciBfcCBpbiAkR0FURVdBWTsgZG8gX289JCgo
X28gKyAxKSk7IFsgIiQoaW50ICIkX3AiIDk5OSkiIC1sZSAyNTUgXSB8fCBfbz05OTsgZG9uZTsg
SUZTPSRfaWZzCiAgICAgWyAiJF9vIiA9IDQgXSB8fCB7IGxvZyAiZ3VhcmQuY29uZiA6IEdBVEVX
QVk9JEdBVEVXQVkgaW52YWxpZGUsIHBhc3NlcmVsbGUgbHVlIGRhbnMgbGEgdGFibGUgZGUgcm91
dGFnZSI7IEdBVEVXQVk9OyB9IDs7CmVzYWMKSEVBTFRIPSRSVU4vaGVhbHRoCkNNRD0kUlVOL2Nt
ZApTVEFUVVM9JFJVTi9ndWFyZC1zdGF0dXMKbWtkaXIgLXAgIiRDTUQiIDI+L2Rldi9udWxsCgoj
IFVuIHNldWwgc3VydmVpbGxhbnQgYSBsYSBmb2lzCkdMPSRSVU4vZ3VhcmQubG9jawppZiAhIG1r
ZGlyICIkR0wiIDI+L2Rldi9udWxsOyB0aGVuCiAgcmQgb3AgIiRHTC9waWQiIDAKICBbICIkb3Ai
ID0gMCBdICYmIHsgc2xlZXAgMTsgcmQgb3AgIiRHTC9waWQiIDA7IH0gICAgICAjIHY1IDogdmVy
cm91IGVuIGNvdXJzIGRlIGNyZWF0aW9uIChwaWQgcGFzIGVuY29yZSBlY3JpdCkgOiBuZSBwYXMg
bGUgdm9sZXIKICBpZiBbICIkb3AiICE9IDAgXSAmJiBraWxsIC0wICIkb3AiIDI+L2Rldi9udWxs
OyB0aGVuIGV4aXQgMDsgZmkKICBybSAtcmYgIiRHTCI7IG1rZGlyICIkR0wiIDI+L2Rldi9udWxs
IHx8IGV4aXQgMQpmaQplY2hvICQkID4gIiRHTC9waWQiCnRyYXAgJ3JtIC1yZiAiJEdMIicgRVhJ
VAp0cmFwICdleGl0IDAnIFRFUk0gSU5UIEhVUAoKIyAtLS0gbGVjdHVyZXMgc2FucyBwcm9jZXNz
dXMgLS0tCmhlYWx0aF9yZWFkKCkgeyAjIHBvc2UgSF90cyBIX3VwIEhfbXF0dCBIX2Jyb2tlciBI
X29rIDsgcmV0b3VyIDEgc2kgcGFzIGRlIGZpY2hpZXIKICBIX3RzPTA7IEhfdXA9MDsgSF9tcXR0
PTsgSF9icm9rZXI9OyBIX29rPQogIFsgLXMgIiRIRUFMVEgiIF0gfHwgcmV0dXJuIDEKICB3aGls
ZSBJRlM9Jz0nIHJlYWQgLXIgayB2OyBkbwogICAgY2FzZSAiJGsiIGluIHRzKSBIX3RzPSR2Ozsg
dXApIEhfdXA9JHY7OyBtcXR0KSBIX21xdHQ9JHY7OyBtcXR0X2Jyb2tlcikgSF9icm9rZXI9JHY7
OyBhcHBfb2spIEhfb2s9JHY7OyBlc2FjCiAgZG9uZSA8ICIkSEVBTFRIIgogIHJldHVybiAwCn0K
aGVhbHRoX2FnZSgpIHsgIyBwb3NlIEhfYWdlIChzKSBkJ2FwcmVzIGwndXB0aW1lIGVjcml0IHBh
ciBsJ2FwcGxpY2F0aW9uLCBzaW5vbiBkJ2FwcmVzIGwnaG9ybG9nZQogIHRvaW50IEhfdXAgMDsg
dG9pbnQgSF90cyAwCiAgaWYgWyAiJEhfdXAiIC1ndCAwIF07IHRoZW4gSF9hZ2U9JCgoIFVQIC0g
SF91cCApKTsgWyAiJEhfYWdlIiAtbHQgMCBdICYmIEhfYWdlPTk5OTk5OQogIGVsc2UgSF9hZ2U9
JCgoICQobm93KSAtIEhfdHMgKSk7IGZpCn0KbWVtX2F2YWlsKCkgeyBNQT0wOyB3aGlsZSByZWFk
IC1yIGsgdiB1OyBkbyBjYXNlICIkayIgaW4gTWVtQXZhaWxhYmxlOikgTUE9JHY7IGJyZWFrOzsg
ZXNhYzsgZG9uZSA8IC9wcm9jL21lbWluZm87IH0KIyBwbGFjZSBsaWJyZSAoS2lvKSBkJ3VuIG1v
bnRhZ2UgOiB1biBzZXVsIHByb2dyYW1tZSAoZGYgLVAsIHVuZSBsaWduZSBwYXIgbW9udGFnZSkg
ZXQgdW5lIGxlY3R1cmUgaW50ZXJuZSwgcGFzIGQnYXdrIChzb2JyaWV0ZSwgRzE4KQpmcmVlX2ti
KCkgeyBkZiAta1AgIiQxIiAyPi9kZXYvbnVsbCB8IHsgcmVhZCAtciBfaDsgcmVhZCAtciBfYSBf
YiBfYyBfZCBfZTsgY2FzZSAiJF9kIiBpbiAnJ3wqWyEwLTldKikgOzsgKikgZWNobyAiJF9kIjs7
IGVzYWM7IH07IH0KY2hpbGRfYWxpdmUoKSB7IGxpdmVfY2hpbGQ7IH0gICAgICMgbCdhcHBsaWNh
dGlvbiBsYW5jZWUgcGFyIGxlIGxhbmNldXIgdG91cm5lLXQtZWxsZSBlbmNvcmUgKG1lbWUgbnVt
ZXJvLCBtZW1lIG5vbSkgPwppc19sYXVuY2hlcigpIHsgWyAiJChoZWFkIC1jIDIgIiRMQVVOQ0hF
UiIgMj4vZGV2L251bGwpIiA9ICcjIScgXTsgfSAgICMgL2RhdGEvb3BlbnFpYXJhZCBlc3QtaWwg
ZW5jb3JlIGxlIGxhbmNldXIgPwpzZWVuX2hlYWx0aCgpIHsgWyAtZSAiJChzZCAiJDEiKS9IRUFM
VEhfU0VFTiIgXTsgfSAgICAgICAgICAgICAgICAgICAgICAjIGNldHRlIHZlcnNpb24gYS10LWVs
bGUgZGVqYSBlY3JpdCBzYSBzYW50ZSA/Cm5vdGVfaGVhbHRoKCkgeyBbICIkMSIgPSBtZWRpYS1v
bGQgXSB8fCBbICIkMSIgPSBub25lIF0gfHwgc2Vlbl9oZWFsdGggIiQxIiB8fCB0cnVlIDI+L2Rl
di9udWxsID4gIiQoc2QgIiQxIikvSEVBTFRIX1NFRU4iOyB9Cmhhbmdfa2lsbCgpIHsgIyBoYW5n
X2tpbGwgcmFpc29uIDogYXJyZXQgZm9yY2UgY29tcHRlIGNvbW1lIHVuIGVjaGVjIChlc3NhaSA6
IHJldG91ciBhcnJpZXJlIGFwcmVzIFRSSUFMX0hBTkdfTUFYKQogIGlmIFsgLWUgIiRTVC90cmlh
bCIgXSAmJiBbICIkcnNsIiA9IG5ldyBdOyB0aGVuIDoKICBlbGlmICEgcmF0ZV9vayBoYW5na2ls
bCAiJEhBTkdfTUFYX0hPVVIiIDM2MDA7IHRoZW4gbG9nICJhcHBsaWNhdGlvbiBmaWdlZSAoJDEp
IG1haXMgZGVqYSAkSEFOR19NQVhfSE9VUiBhcnJldHMgZW4gMSBoIDogcmllbiBkZSBwbHVzIjsg
cmV0dXJuIDAKICBmaQogIGhhbmdfa2lsbHM9JCgoaGFuZ19raWxscyArIDEpKQogIGxvZyAiYXBw
bGljYXRpb24gZmlnZWUgKCQxKSA6IGFycmV0IGZvcmNlICgkaGFuZ19raWxscykiCiAgc3RvcF9j
aGlsZDsgcm0gLWYgIiRTVC9leHBlY3RlZF9zdG9wIiAgICAgIyB1biBibG9jYWdlIGNvbXB0ZSBj
b21tZSB1biBlY2hlYyBwb3VyIGxlIGxhbmNldXIKICBpZiBbIC1lICIkU1QvdHJpYWwiIF0gJiYg
WyAiJGhhbmdfa2lsbHMiIC1nZSAiJFRSSUFMX0hBTkdfTUFYIiBdOyB0aGVuCiAgICBzaCAiJFFQ
L3FwLXVwZGF0ZSIgcm9sbGJhY2sgImVzc2FpIGZpZ2UiID4+ICIkTE9HIiAyPiYxOyBoYW5nX2tp
bGxzPTAKICBmaQp9Cmxpc3RlbmluZygpIHsgIyBwb3NlIEwyMiBldCBMMjIyMiAoU1NIIGRlIHNl
Y291cnMsIMKrIG9mZiDCuyBzYW5zIGx1aSkgZCdhcHJlcyAvcHJvYy9uZXQvdGNwIChldGF0IDBB
ID0gZWNvdXRlKQogIEwyMj0wOyBMMjIyMj0wOyBfaHg9JChwcmludGYgJyUwNFgnICIkU1NIX1NF
Q09VUlNfUE9SVCIgMj4vZGV2L251bGwpCiAgd2hpbGUgcmVhZCAtciBfc2wgX2xhIF9yYSBfc3Qg
X3Jlc3Q7IGRvCiAgICBjYXNlICIkX3N0OiRfbGEiIGluIDBBOio6MDAxNikgTDIyPTE7OyAwQToq
OiIkX2h4IikgWyAiJFNTSF9TRUNPVVJTX1BPUlQiIC1ndCAwIF0gJiYgTDIyMjI9MTs7IGVzYWMK
ICBkb25lIDwgIiRORVRfVENQIgogIFsgIiRTU0hfU0VDT1VSU19QT1JUIiAtZ3QgMCBdIHx8IEwy
MjIyPW9mZgp9CmdhdGV3YXkoKSB7ICMgcGFzc2VyZWxsZSBwYXIgZGVmYXV0IGQnYXByZXMgL3By
b2MvbmV0L3JvdXRlIChoZXhhZGVjaW1hbCBwZXRpdC1ib3V0aXN0ZSkKICBbIC1uICIkR0FURVdB
WSIgXSAmJiB7IEdXPSRHQVRFV0FZOyByZXR1cm47IH0KICBHVz0KICB3aGlsZSByZWFkIC1yIF9p
ZiBfZHN0IF9ndyBfcmVzdDsgZG8KICAgIFsgIiRfZHN0IiA9IDAwMDAwMDAwIF0gJiYgWyAiJF9n
dyIgIT0gMDAwMDAwMDAgXSAmJiB7IEdXPSIkKCgweCRfZ3cgJiAyNTUpKS4kKCgweCRfZ3cgPj4g
OCAmIDI1NSkpLiQoKDB4JF9ndyA+PiAxNiAmIDI1NSkpLiQoKDB4JF9ndyA+PiAyNCAmIDI1NSkp
IjsgYnJlYWs7IH0KICBkb25lIDwgL3Byb2MvbmV0L3JvdXRlIDI+L2Rldi9udWxsCn0KcGFzc2l2
ZSgpIHsgWyAiJFBBU1NJVkUiID0gMSBdICYmIHsgbG9nICIocGFzc2lmLCBub24gZmFpdCkgJCoi
OyByZXR1cm4gMDsgfTsgcmV0dXJuIDE7IH0Kc3RvcF9jaGlsZCgpIHsgIyBhcnJldCB2b2xvbnRh
aXJlIDogbGUgbGFuY2V1ciBuZSBsZSBjb21wdGVyYSBwYXMgY29tbWUgdW4gcGxhbnRhZ2UKICBw
YXNzaXZlICJhcnJldCBkZSBsJ2FwcGxpY2F0aW9uIiAmJiByZXR1cm4gMAogIGxpdmVfY2hpbGQg
fHwgeyBsb2cgImFycmV0IGRlbWFuZGUgbWFpcyBhdWN1bmUgYXBwbGljYXRpb24gZW4gY291cnMg
KG51bWVybyBhYnNlbnQgb3UgcGVyaW1lKSA6IHJpZW4gZmFpdCI7IHJldHVybiAwOyB9CiAgdHJ1
ZSAyPi9kZXYvbnVsbCA+ICIkU1QvZXhwZWN0ZWRfc3RvcCIKICBraWxsICIkQ0giIDI+L2Rldi9u
dWxsCiAgX2k9MDsgd2hpbGUgWyAkX2kgLWx0IDggXSAmJiBraWxsIC0wICIkQ0giIDI+L2Rldi9u
dWxsOyBkbyBzbGVlcCAxOyBfaT0kKChfaSsxKSk7IGRvbmUKICBraWxsIC0wICIkQ0giIDI+L2Rl
di9udWxsICYmIGtpbGwgLTkgIiRDSCIgMj4vZGV2L251bGwKICByZXR1cm4gMAp9CnJhdGVfb2so
KSB7ICMgcmF0ZV9vayBub20gbWF4IGZlbmV0cmUgOiBhdXRvcmlzZSBzaSBtb2lucyBkZSBtYXgg
Zm9pcyBzdXIgbGEgZmVuZXRyZSA7IGVuIGNhcyBkZSBkb3V0ZSwgY29tcHRlCiAgIyB2NiA6IGNo
YXF1ZSBldmVuZW1lbnQgZXN0IG5vdGUgInVwdGltZTpob3Jsb2dlOmJvb3RfaWQiLiBTb24gYWdl
IHNlIG1lc3VyZSBzdXIgbCd1cHRpbWUgZGFucyBsZSBtZW1lIGRlbWFycmFnZSAobCdob3Jsb2dl
CiAgIyBtdXJhbGUgcGFydCBkZSAxOTcwIGV0IHNhdXRlIGF1IHJlZ2xhZ2UgTlRQIDogYXZlYyBl
bGxlLCBsZSBzYXV0IGZhaXNhaXQgb3VibGllciB0b3VzIGxlcyBldmVuZW1lbnRzIHBhc3Nlcyks
IHN1ciBsJ2hvcmxvZ2UKICAjIGFwcmVzIHVuIHJlZGVtYXJyYWdlIHNpIGVsbGUgZXN0IHBsYXVz
aWJsZSBkZXMgZGV1eCBjb3RlcywgZXQgc2lub24gaWwgdmF1dCBsJ3VwdGltZSBjb3VyYW50IChs
J2V2ZW5lbWVudCBkYXRlIGQnYXZhbnQgY2UKICAjIGRlbWFycmFnZSA6IGlsIHJlc3RlIGNvbXB0
ZSBqdXNxdSdhIGNlIHF1ZSBsYSBjYW1lcmEgYWl0IHRvdXJuZSB0b3V0ZSBsYSBmZW5ldHJlKS4g
TGVzIGFuY2llbnMgZmljaGllcnMgKGhvcmxvZ2Ugc2V1bGUpCiAgIyBzb250IGx1cyBjb21tZSBk
ZXMgZXZlbmVtZW50cyBkJ3VuIGF1dHJlIGRlbWFycmFnZS4KICBfZj0kU1QvcmF0ZV8kMTsgX2tl
ZXA9OyBfbj0wOyBfbGluZT0KICB1cF9ub3c7IGJvb3RfaWQ7IF90PSQobm93KQogIFsgLXMgIiRf
ZiIgXSAmJiByZWFkIC1yIF9saW5lIDwgIiRfZiIKICBmb3IgX3ggaW4gJF9saW5lOyBkbwogICAg
Y2FzZSAiJF94IiBpbgogICAgICAqOio6KikgX3h1PSR7X3glJToqfTsgX3hyPSR7X3gjKjp9OyBf
eHc9JHtfeHIlJToqfTsgX3hiPSR7X3hyIyo6fSA7OwogICAgICAqKSBfeHU9MDsgX3h3PSRfeDsg
X3hiPTsgdG9pbnQgX3h3IDA7IFsgIiRfeHciIC1ndCAxNzAwMDAwMDAwIF0gfHwgY29udGludWUg
OzsgICAjIGFuY2llbiBmb3JtYXQgOiBob3Jsb2dlIHBsYXVzaWJsZSBzZXVsZW1lbnQgKGNvbW1l
IGVuIHY1KQogICAgZXNhYwogICAgdG9pbnQgX3h1IDA7IHRvaW50IF94dyAwCiAgICBbICIkX3h1
IiAtZ3QgMCBdIHx8IFsgIiRfeHciIC1ndCAwIF0gfHwgY29udGludWUgICAgICAjIGpldG9uIGls
bGlzaWJsZSA6IGlnbm9yZQogICAgaWYgWyAtbiAiJF94YiIgXSAmJiBbICIkX3hiIiA9ICIkQk9P
VCIgXTsgdGhlbiBfYWdlPSQoKFVQIC0gX3h1KSk7IFsgIiRfYWdlIiAtbHQgMCBdICYmIF9hZ2U9
MAogICAgZWxpZiBbICIkX3QiIC1ndCAxNzAwMDAwMDAwIF0gJiYgWyAiJF94dyIgLWd0IDE3MDAw
MDAwMDAgXSAmJiBbICIkX3QiIC1nZSAiJF94dyIgXTsgdGhlbiBfYWdlPSQoKF90IC0gX3h3KSkK
ICAgIGVsc2UgX2FnZT0kVVA7IGZpCiAgICBbICIkX2FnZSIgLWx0ICIkMyIgXSAmJiB7IF9rZWVw
PSIkX2tlZXAgJF94IjsgX249JCgoX24rMSkpOyB9CiAgZG9uZQogIGlmIFsgIiRfbiIgLWdlICIk
MiIgXTsgdGhlbiBlY2hvICRfa2VlcCA+ICIkX2YiOyByZXR1cm4gMTsgZmkKICBlY2hvICRfa2Vl
cCAiJFVQOiRfdDokQk9PVCIgPiAiJF9mIjsgcmV0dXJuIDAKfQojICh2OSkgYm91bmRlZCBTRUMg
Y21kLi4uIDogbGFuY2UgbGEgY29tbWFuZGUgZW4gYXJyaWVyZS1wbGFuIGV0IGF0dGVuZCBhdSBw
bHVzIFNFQyBzZWNvbmRlcyA7IGF1LWRlbGEsIGwnYXJyZXRlIChURVJNIHB1aXMgS0lMTCkKIyBl
dCBqb3VybmFsaXNlLiBMZSBzdXJ2ZWlsbGFudCBlc3QgdW5lIGJvdWNsZSBhIHVuIHNldWwgZmls
IDogdW5lIGNvbW1hbmRlIHF1aSBuZSByZW5kIHBhcyBsYSBtYWluIChmYnh1cHN0YXJ0Y3RsIG91
IGZieGJ1c2N0bCBzdXIKIyB1biBidXMgbW9ydCwgc3luYyBzdXIgdW5lIGNhcnRlIFNEIG11ZXR0
ZSwgZGVtb24gcXVpIG5lIHNlIGRldGFjaGUgcGFzKSBsYSBmaWdlYWl0IGp1c3F1ZS1sYSAob2Jz
ZXJ2YXRpb24gZHUgYmFuYyBkdSAyNy8xMC8yMDI2KS4KIyBQYXMgZCdhcHBsZXQgdGltZW91dCBz
dXIgbGEgY2FtZXJhIDogYXR0ZW50ZSBwYXIgc29uZGFnZSBkZSAvcHJvYy88cGlkPi4gU29ydGll
IGV0IGVycmV1cnMgZGUgbGEgY29tbWFuZGUgdmVycyAvZGV2L251bGwuCmJvdW5kZWQoKSB7CiAg
X2J0PSQxOyBzaGlmdAogICIkQCIgPi9kZXYvbnVsbCAyPiYxICYKICBfYnA9JCE7IF9iaT0wCiAg
d2hpbGUgWyAtZCAiL3Byb2MvJF9icCIgXSAmJiBbICRfYmkgLWx0ICIkX2J0IiBdOyBkbyBzbGVl
cCAxOyBfYmk9JCgoX2JpKzEpKTsgZG9uZQogIGlmIFsgLWQgIi9wcm9jLyRfYnAiIF07IHRoZW4K
ICAgIGtpbGwgIiRfYnAiIDI+L2Rldi9udWxsOyBzbGVlcCAxCiAgICBbIC1kICIvcHJvYy8kX2Jw
IiBdICYmIHsga2lsbCAtOSAiJF9icCIgMj4vZGV2L251bGw7IHNsZWVwIDE7IH0KICAgIGlmIFsg
LWQgIi9wcm9jLyRfYnAiIF0gJiYgISBncmVwIC1xICdeU3RhdGU6W1s6c3BhY2U6XV0qWicgIi9w
cm9jLyRfYnAvc3RhdHVzIiAyPi9kZXYvbnVsbDsgdGhlbgogICAgICAjIHNvbW1laWwgaW5pbnRl
cnJ1cHRpYmxlIChjYXJ0ZSBTRCBvdSBidXMgbXVldCkgOiBtZW1lIEtJTEwgYXR0ZW5kIGxhIGZp
biBkZSBsJ2FwcGVsIHN5c3RlbWUgOyBuZSBwYXMgYXR0ZW5kcmUgYXZlYyBsdWkKICAgICAgbG9n
ICJjb21tYW5kZSBzYW5zIHJlcG9uc2UgYXByZXMgJF9idCBzIGV0IHNvdXJkZSBhIGwnYXJyZXQg
KGVudHJlZS9zb3J0aWUgYmxvcXVlZSA/KSA6ICQxICR7Mi19IChwaWQgJF9icCBhYmFuZG9ubmUp
IgogICAgICByZXR1cm4gMTI0CiAgICBmaQogICAgbG9nICJjb21tYW5kZSBzYW5zIHJlcG9uc2Ug
YXByZXMgJF9idCBzLCBhcnJldGVlIDogJDEgJHsyLX0iCiAgICB3YWl0ICIkX2JwIiAyPi9kZXYv
bnVsbDsgcmV0dXJuIDEyNAogIGZpCiAgd2FpdCAiJF9icCIgMj4vZGV2L251bGwKfQpkb19yZWJv
b3QoKSB7CiAgcGFzc2l2ZSAicmVkZW1hcnJhZ2UgKCQxKSIgJiYgcmV0dXJuIDEKICBbICIkRU5B
QkxFX1JFQk9PVCIgPSAxIF0gfHwgeyBsb2cgInJlZGVtYXJyYWdlIGRlbWFuZGUgKCQxKSBtYWlz
IGRlc2FjdGl2ZSI7IHJldHVybiAxOyB9CiAgIyB2NiA6IGxlcyBvcmRyZXMgZGUgSG9tZSBBc3Np
c3RhbnQgb250IGxldXIgcHJvcHJlIGJ1ZGdldCAoT1JERVJfUkVCT09UX01BWCkgOiB1biBjbGll
bnQgTVFUVCBvdSB1bmUgYXV0b21hdGlzYXRpb24gbmUgcGV1dAogICMgcGx1cyBlcHVpc2VyIGxl
IGJ1ZGdldCBkZXMgcmVkZW1hcnJhZ2VzIGF1dG9tYXRpcXVlcyAocGFzc2VyZWxsZSBtdWV0dGUp
LCBuaSBsJ2ludmVyc2UuCiAgY2FzZSAiJDEiIGluCiAgICAib3JkcmUgSEEiKikgaWYgWyAiJE9S
REVSX1JFQk9PVF9NQVgiIC1ndCAwIF0gJiYgISByYXRlX29rIG9yZGVyX3JlYm9vdCAiJE9SREVS
X1JFQk9PVF9NQVgiICIkUkVCT09UX1dJTkRPVyI7IHRoZW4gbG9nICJyZWRlbWFycmFnZSByZWZ1
c2UgKCQxKSA6IGRlamEgJE9SREVSX1JFQk9PVF9NQVggc3VyIG9yZHJlIGVuICQoKFJFQk9PVF9X
SU5ET1cvMzYwMCkpIGgiOyByZXR1cm4gMTsgZmkgOzsgICAjIHYxMCA6IDAgPSBzYW5zIGxpbWl0
ZQogICAgKikgaWYgISByYXRlX29rIHJlYm9vdCAiJFJFQk9PVF9NQVgiICIkUkVCT09UX1dJTkRP
VyI7IHRoZW4gbG9nICJyZWRlbWFycmFnZSByZWZ1c2UgKCQxKSA6IGRlamEgJFJFQk9PVF9NQVgg
ZW4gJCgoUkVCT09UX1dJTkRPVy8zNjAwKSkgaCI7IHJldHVybiAxOyBmaSA7OwogIGVzYWMKICBj
YXNlICIkMSIgaW4gIm9yZHJlIEhBIiopIDs7ICopIHNuYXBzaG90ICJhdmFudCByZWRlbWFycmFn
ZSA6ICQxIiA7OyBlc2FjCiAgbG9nICJSRURFTUFSUkFHRSBkZSBsYSBjYW1lcmEgOiAkMSIKICBw
dXQgIiRTVC9sYXN0X3JlYm9vdF9yZWFzb24iICIkKHRzKSAkMSIKICBib3VuZGVkIDEwIHN5bmMK
ICAoIHNsZWVwIDE7IHJlYm9vdDsgc2xlZXAgMjU7IGVjaG8gYiA+ICIkU1lTUlEiICkgJgogIHJl
dHVybiAwCn0Kd2lmaV9sMSgpIHsgcGFzc2l2ZSAiV2ktRmkgbml2ZWF1IDEgKCQxKSIgJiYgcmV0
dXJuIDE7IFsgIiRFTkFCTEVfV0lGSV9BQ1RJT05TIiA9IDEgXSB8fCByZXR1cm4gMQogIGxvZyAi
V2ktRmkgbml2ZWF1IDEgKCQxKSA6IGRlY29ubmV4aW9uLCBobGNvbm5tYW4gc2UgcmVhc3NvY2ll
IgogIGJvdW5kZWQgMTUgZmJ4YnVzY3RsIGNhbGwgaGxjb25ubWFuIHdpZmlfZGlzY29ubmVjdDsg
fQp3aWZpX2wyKCkgeyBwYXNzaXZlICJXaS1GaSBuaXZlYXUgMiAoJDEpIiAmJiByZXR1cm4gMTsg
WyAiJEVOQUJMRV9XSUZJX0FDVElPTlMiID0gMSBdIHx8IHJldHVybiAxCiAgbG9nICJXaS1GaSBu
aXZlYXUgMiAoJDEpIDogcmVjaGFyZ2VtZW50IGR1IHBpbG90ZSAoZmJ4dXBzdGFydGN0bCByZXN0
YXJ0IGhsY29ubm1hbikiCiAgYm91bmRlZCAyMCBmYnh1cHN0YXJ0Y3RsIHJlc3RhcnQgaGxjb25u
bWFuOyB9CiMgKHY4KSBkcm9wYmVhciAyMjIyLCBjZWx1aSBkZSBRaWFyYSBQbHVzIDogbGFuY2Ug
YXZlYyB1biBtYWludGllbiBkZSBjb25uZXhpb24gKC1LIDMwIDogdW4gcGFxdWV0IGRlIG1haW50
aWVuIHRvdXRlcyBsZXMgMzAgcywKIyBsYSBzZXNzaW9uIHRvbWJlIGF1IGJvdXQgZGUgMyBzaWxl
bmNlcyBhdSBsaWV1IGRlIHJlc3RlciBhIGphbWFpcyBvdXZlcnRlIGRlcnJpZXJlIHVuIFdpLUZp
IGNvdXBlKSA7IC1zIHNhbnMgbW90IGRlIHBhc3NlLAojIC1nIHBhcyBkZSBtb3QgZGUgcGFzc2Ug
cG91ciByb290IChjbGUgc2V1bGVtZW50KS4gTGUgbnVtZXJvIGR1IHByb2Nlc3N1cyBkJ2Vjb3V0
ZSBlc3QgZGFucyBEUk9QQkVBUl9QSUQuCkRST1BCRUFSX1BJRD0ke1FQX0RST1BCRUFSX1BJRDot
L3Zhci9ydW4vZHJvcGJlYXItMjIyMi5waWR9CnN0YXJ0X2Ryb3BiZWFyXzIyMjIoKSB7IFsgIiRT
U0hfU0VDT1VSU19QT1JUIiAtZ3QgMCBdIHx8IHJldHVybiAwOyBib3VuZGVkIDEwICIkRFJPUEJF
QVIiIC1zIC1nIC1wICIkU1NIX1NFQ09VUlNfUE9SVCIgLUsgMzAgLVAgIiREUk9QQkVBUl9QSUQi
OyB9ICAgIyBkcm9wYmVhciBzZSBkZXRhY2hlIGRlIGx1aS1tZW1lIDsgYm9ybmUgcGFyIHNlY3Vy
aXRlICh2OSkKIyAodjgpIG9yZHJlIHNzaC1yZXN0YXJ0IGRlIEhvbWUgQXNzaXN0YW50IDogcmVs
YW5jZSBkZXMgZGV1eCBlY291dGVzIFNTSCwgY2VsbGUgZGUgUWlhcmEgUGx1cyAoMjIyMiA6IGFy
cmV0IGR1IHByb2Nlc3N1cyBkb250IGxlCiMgbnVtZXJvIGVzdCBkYW5zIGxlIGZpY2hpZXIgcGlk
LCBzZXVsZW1lbnQgcydpbCBwb3J0ZSBsZSBub20gZHJvcGJlYXIsIHB1aXMgcmVsYW5jZSkgZXQg
Y2VsbGUgZHUgY29uc3RydWN0ZXVyICgyMiA6IGZieHVwc3RhcnRjdGwKIyByZXN0YXJ0IGRyb3Bi
ZWFyKS4gTGVzIHNlc3Npb25zIGRlamEgb3V2ZXJ0ZXMgc29udCBkZXMgcHJvY2Vzc3VzIGEgcGFy
dCA6IGVsbGVzIG5lIHNvbnQgcGFzIHRvdWNoZWVzLiBMZSBkcm9wYmVhciBkJ29yaWdpbmUKIyB0
YXJkZSBwYXJmb2lzIGEgcmVuZHJlIHNhIGJhbm5pZXJlIGFsb3JzIHF1ZSBjZWx1aSBkZSBRaWFy
YSBQbHVzIHJlcG9uZCAoMjcvMTAvMjAyNikgOiBjZXQgb3JkcmUgZXN0IGxlIHJlbWVkZSBzYW5z
IHJlZGVtYXJyYWdlLgpzc2hfcmVzdGFydCgpIHsKICBwYXNzaXZlICJyZWxhbmNlIGRlIGRyb3Bi
ZWFyIDIyIGV0IDIyMjIgKCQxKSIgJiYgcmV0dXJuIDAKICByZCBfZHAgIiREUk9QQkVBUl9QSUQi
IDA7IHRvaW50IF9kcCAwCiAgaWYgWyAiJF9kcCIgIT0gMCBdICYmIFsgIiRTU0hfU0VDT1VSU19Q
T1JUIiAtZ3QgMCBdOyB0aGVuCiAgICBfZGM9OyByZWFkIC1yIF9kYyA8ICIvcHJvYy8kX2RwL2Nv
bW0iIDI+L2Rldi9udWxsCiAgICBpZiBbICIkX2RjIiA9IGRyb3BiZWFyIF07IHRoZW4KICAgICAg
a2lsbCAiJF9kcCIgMj4vZGV2L251bGwKICAgICAgIyAodjkpIGF0dGVuZHJlIGwnYXJyZXQgZWZm
ZWN0aWYgKDUgcyBhdSBwbHVzLCBwdWlzIEtJTEwpIDogc2lub24gbGEgbm91dmVsbGUgZWNvdXRl
IDIyMjIgZWNob3VhaXQgZW4gc2lsZW5jZQogICAgICBfYmk9MDsgd2hpbGUgWyAtZCAiL3Byb2Mv
JF9kcCIgXSAmJiBbICRfYmkgLWx0IDUgXTsgZG8gc2xlZXAgMTsgX2JpPSQoKF9iaSsxKSk7IGRv
bmUKICAgICAgWyAtZCAiL3Byb2MvJF9kcCIgXSAmJiB7IGtpbGwgLTkgIiRfZHAiIDI+L2Rldi9u
dWxsOyBzbGVlcCAxOyBsb2cgImRyb3BiZWFyIDIyMjIgOiBhbmNpZW4gcHJvY2Vzc3VzICRfZHAg
YXJyZXRlIGRlIGZvcmNlIjsgfQogICAgZWxzZSBsb2cgImRyb3BiZWFyIDIyMjIgOiBudW1lcm8g
JF9kcCBwZXJpbWUgKHByb2Nlc3N1cyAke19kYzotYWJzZW50fSksIHBhcyBkJ2FycmV0IjsgZmkK
ICBmaQogIHN0YXJ0X2Ryb3BiZWFyXzIyMjIKICBib3VuZGVkIDIwIGZieHVwc3RhcnRjdGwgcmVz
dGFydCBkcm9wYmVhcgogIHNsZWVwIDE7IGxpc3RlbmluZwogIGxvZyAiZHJvcGJlYXIgMjIgZXQg
MjIyMiByZWxhbmNlcyAoJDEpIDogZWNvdXRlIDIyPSRMMjIgMjIyMj0kTDIyMjIiCiAgWyAiJEwy
MjIyIiA9IDAgXSAmJiBsb2cgImRyb3BiZWFyIDIyMjIgbidlY291dGUgcGFzIGFwcmVzIGxhIHJl
bGFuY2UgOiBub3V2ZWwgZXNzYWkgYXUgcHJvY2hhaW4gcGFzc2FnZSBsZW50Igp9CiMgdjQgOiBp
bnN0YW50YW5lIGQnaW5jaWRlbnQuIExhIGJvaXRlIG5vaXJlICgvdG1wL2JiLmxvZyksIGRtZXNn
IGV0IGwnZXRhdCBkdSByZXNlYXUgdml2ZW50IGVuIG1lbW9pcmUgdml2ZSA6IHVuCiMgcmVkZW1h
cnJhZ2UgbGVzIGVmZmFjZSAoaW5jaWRlbnQgZGUgMjAgaCAyOCBsZSAyNi8xMC8yMDI2KS4gQ29w
aWVzIHN1ciAvbWVkaWEvcXAvaW5jaWRlbnRzICg2IGdhcmRlcywgfjEgTW8gY2hhY3VuKSwKIyBy
ZXBsaSBzdXIgL2RhdGEvcXAvaW5jaWRlbnQgKHVuIHNldWwsIHBldGl0KSBzaSAvbWVkaWEgbmUg
cmVwb25kIHBhcy4gUHJpcyBhdSByZWNoYXJnZW1lbnQgZHUgcGlsb3RlIFdpLUZpLCBhdmFudCB1
bgojIHJlZGVtYXJyYWdlIGF1dG9tYXRpcXVlIGV0IGF1IHJldG91ciBkJ3VuZSBjb3VwdXJlIGQn
YXUgbW9pbnMgSU5DSURFTlRfTUlOX1NFQy4KSU5DSURFTlRTPSR7UVBfSU5DSURFTlRTOi0kQlVM
Sy9pbmNpZGVudHN9CklOQ0lERU5UX0tFRVA9NgpzbmFwc2hvdCgpIHsKICBwYXNzaXZlICJpbnN0
YW50YW5lICgkMSkiICYmIHJldHVybiAwCiAgX3NtYWxsPTsgX2Q9JElOQ0lERU5UUy8kKGRhdGUg
JyslWSVtJWQtJUglTSVTJykKICBpZiAhIG1rZGlyIC1wICIkX2QiIDI+L2Rldi9udWxsIHx8ICEg
OiA+ICIkX2QvLm9rIiAyPi9kZXYvbnVsbDsgdGhlbgogICAgX3NtYWxsPTE7IF9kPSRRUC9pbmNp
ZGVudDsgcm0gLXJmICIkX2QiOyBta2RpciAtcCAiJF9kIiAyPi9kZXYvbnVsbCB8fCByZXR1cm4g
MAogIGZpCiAgcm0gLWYgIiRfZC8ub2siCiAgeyBlY2hvICJyYWlzb249JDEiOyBlY2hvICJ1cHRp
bWU9JFVQIjsgZGF0ZTsgZWNobyAiLS0tIHN1cnZlaWxsYW50IjsgY2F0ICIkU1RBVFVTIjsgZWNo
byAiLS0tIHNhbnRlIjsgY2F0ICIkSEVBTFRIIgogICAgZWNobyAiLS0tIG1lbW9pcmUiOyBncmVw
IC1FICdeKE1lbUZyZWV8TWVtQXZhaWxhYmxlfENhY2hlZHxTbGFifFNVbnJlY2xhaW0pOicgL3By
b2MvbWVtaW5mbzsgY2F0IC9wcm9jL2xvYWRhdmc7IH0gPiAiJF9kL2V0YXQudHh0IiAyPiYxCiAg
ZG1lc2cgMj4vZGV2L251bGwgfCB0YWlsIC1uIDMwMCA+ICIkX2QvZG1lc2cudHh0IgogIHsgZWNo
byAiLS0tIGludGVyZmFjZXMiOyBjYXQgL3Byb2MvbmV0L2RldjsgY2F0IC9wcm9jL25ldC93aXJl
bGVzczsgZWNobyAiLS0tIHJvdXRlcyI7IGNhdCAvcHJvYy9uZXQvcm91dGU7IGVjaG8gIi0tLSBh
cnAiOyBjYXQgL3Byb2MvbmV0L2FycAogICAgZWNobyAiLS0tIHRjcCI7IGNhdCAvcHJvYy9uZXQv
dGNwOyBjYXQgL3Byb2MvbmV0L3RjcDY7IGVjaG8gIi0tLSBzbm1wIjsgY2F0IC9wcm9jL25ldC9z
bm1wOyB9ID4gIiRfZC9yZXNlYXUudHh0IiAyPiYxCiAgZm9yIF9wIGluIC9wcm9jL1swLTldKjsg
ZG8gcmVhZCAtciBfYyA8ICIkX3AvY29tbSIgMj4vZGV2L251bGwgfHwgY29udGludWUKICAgIGVj
aG8gIiR7X3AjL3Byb2MvfSAkX2MgJChncmVwIC1FICdeKFN0YXRlfFZtUlNTKTonICIkX3Avc3Rh
dHVzIiAyPi9kZXYvbnVsbCB8IHRyIC1zICcgXHRcbicgJyAnKSI7IGRvbmUgPiAiJF9kL3Byb2Nl
c3N1cy50eHQiIDI+JjEKICBpZiBbIC16ICIkX3NtYWxsIiBdOyB0aGVuCiAgICB0YWlsIC1jIDUy
NDI4OCAiJEJCTE9HIiA+ICIkX2QvYmIubG9nIiAyPi9kZXYvbnVsbDsgdGFpbCAtbiA0MDAgIiRM
T0ciID4gIiRfZC9qb3VybmFsLmxvZyIgMj4vZGV2L251bGwKICAgICMgdjYgOiBsZXMgZG9zc2ll
cnMgZGF0ZXMgZGUgMTk3MCAoaG9ybG9nZSBwYXMgZW5jb3JlIHJlZ2xlZSkgc29udCBjb21wdGVz
IGV0IGVsYWd1ZXMgY29tbWUgbGVzIGF1dHJlcwogICAgX249JChscyAtZCAiJElOQ0lERU5UUyIv
WzAtOV0qIDI+L2Rldi9udWxsIHwgd2MgLWwpCiAgICBbICIkX24iIC1ndCAiJElOQ0lERU5UX0tF
RVAiIF0gJiYgbHMgLWQgIiRJTkNJREVOVFMiL1swLTldKiB8IHNvcnQgfCBoZWFkIC1uICQoKF9u
IC0gSU5DSURFTlRfS0VFUCkpIHwgd2hpbGUgcmVhZCAtciBfbzsgZG8gcm0gLXJmICIkX28iOyBk
b25lCiAgZWxzZQogICAgdGFpbCAtYyAzMjc2OCAiJEJCTE9HIiA+ICIkX2QvYmIubG9nIiAyPi9k
ZXYvbnVsbAogIGZpCiAgYm91bmRlZCAxMCBzeW5jCiAgbG9nICJpbnN0YW50YW5lIGQnaW5jaWRl
bnQgKCQxKSA6ICRfZCIKfQp2aWRlb19jaGVjaygpIHsgIyByZWdsYWdlcyBlZmZlY3RpZnMgZGUg
aGxjYW1kIChkaWFnbm9zdGljIHNldWxlbWVudCwgYXVjdW5lIGFjdGlvbikgOyB2OCA6IGNvZGVj
IGRlbWFuZGUgKC0tdXNlLWgyNjQvLS11c2UtaDI2NSkKICBWX3BpZD07IFZfaXY9PzsgVl9yYXRl
PWRlZmF1dDsgVl9nb3A9ZGVmYXV0OyBWX3NoaW09MDsgVl9jb2RlYz1kZWZhdXQKICBmb3IgX3Ag
aW4gL3Byb2MvWzAtOV0qOyBkbyByZWFkIC1yIF9jIDwgIiRfcC9jb21tIiAyPi9kZXYvbnVsbCAm
JiBbICIkX2MiID0gaGxjYW1kIF0gJiYgeyBWX3BpZD0ke19wIy9wcm9jL307IGJyZWFrOyB9OyBk
b25lCiAgWyAtbiAiJFZfcGlkIiBdIHx8IHsgVl9pdj1hYnNlbnQ7IFZfY29kZWM9YWJzZW50OyBy
ZXR1cm47IH0KICBzZXQgLS0gJCh0ciAnXDAnICcgJyA8IC9wcm9jLyRWX3BpZC9jbWRsaW5lIDI+
L2Rldi9udWxsKQogIHdoaWxlIFsgJCMgLWd0IDAgXTsgZG8KICAgIGNhc2UgIiQxIiBpbiAtLWl2
LWRldGVjdGlvbikgVl9pdj0kMjsgc2hpZnQ7OyAtLTEwODBwLWJpdHJhdGUpIFZfcmF0ZT0kMjsg
c2hpZnQ7OyAtLWdvcC1kZW51bSkgVl9nb3A9JDI7IHNoaWZ0OzsKICAgICAgICAgICAgICAgICAt
LXVzZS1oMjY0KSBWX2NvZGVjPWgyNjQ7OyAtLXVzZS1oMjY1KSBWX2NvZGVjPWgyNjU7OyBlc2Fj
CiAgICBzaGlmdAogIGRvbmUKICB3aGlsZSByZWFkIC1yIF9sOyBkbyBjYXNlICIkX2wiIGluICpx
aWFyYV9zaGltKikgVl9zaGltPTE7IGJyZWFrOzsgZXNhYzsgZG9uZSA8IC9wcm9jLyRWX3BpZC9t
YXBzIDI+L2Rldi9udWxsCn0KCiMgKHY3KSBobGNhbWQgYWJzZW50IGRlcHVpcyBWSURFT19HT05F
X1NFQyA6IHJlZGVtYXJyYWdlIGRlIGxhIGNhbWVyYS4gT3BlblFpYXJhIG5lIGNvbXB0ZSBwbHVz
IGhsY2FtZCBkYW5zIGxhIHNhbnRlIHF1aQojIG5vdXJyaXQgbGUgY2hpZW4gZGUgZ2FyZGUgbWF0
ZXJpZWwgKGhsY2FtZCBhYnNlbnQgPSByZWRlbWFycmFnZSB0b3V0ZXMgbGVzIDUgYSA2IG1pbiBl
dCByYWRpbyBjb3VwZWUgYSBjaGFxdWUgZm9pcykgOyBjJ2VzdCBpY2kKIyBxdWUgbGEgdmlkZW8g
ZXN0IHJlcGFyZWUsIGF2ZWMgbGUgYnVkZ2V0IFJFQk9PVF9NQVggc3VyIFJFQk9PVF9XSU5ET1cg
KGRvX3JlYm9vdCA6IGluc3RhbnRhbmUgZCdhYm9yZCwgam91cm5hbCwgbW9kZSBwYXNzaWYgcmVz
cGVjdGUpLgojIFVuIHJlZGVtYXJyYWdlIHJlZnVzZSAoYnVkZ2V0LCBkZXNhY3RpdmUsIHBhc3Np
Zikgbidlc3QgcmV0ZW50ZSBxdSdhcHJlcyB1biBhdXRyZSBWSURFT19HT05FX1NFQy4gU2FucyAv
cHJvYyBsaXNpYmxlIDogcmllbi4KdmlkZW9fZ29uZV9jaGVjaygpIHsKICBpZiBbICIkVklERU9f
R09ORV9TRUMiIC1sZSAwIF0gfHwgWyAiJFZfaXYiICE9IGFic2VudCBdIHx8ICEgWyAtciAvcHJv
Yy8xL2NvbW0gXTsgdGhlbgogICAgWyAiJGhsX2dvbmVfc2luY2UiIC1nZSAwIF0gJiYgWyAiJFZf
aXYiICE9IGFic2VudCBdICYmIFsgIiRWSURFT19HT05FX1NFQyIgLWd0IDAgXSAmJiBsb2cgImhs
Y2FtZCBkZSBub3V2ZWF1IHByZXNlbnQgYXByZXMgJCgoVVAgLSBobF9nb25lX3NpbmNlKSkgcyIK
ICAgIGhsX2dvbmVfc2luY2U9LTE7IGhsX3RyeV9hdD0tOTk5OTk5OyByZXR1cm4gMAogIGZpCiAg
WyAiJGhsX2dvbmVfc2luY2UiIC1nZSAwIF0gfHwgeyBobF9nb25lX3NpbmNlPSRVUDsgbG9nICJo
bGNhbWQgYWJzZW50IjsgcmV0dXJuIDA7IH0KICBfZD0kKChVUCAtIGhsX2dvbmVfc2luY2UpKQog
IFsgIiRfZCIgLWdlICIkVklERU9fR09ORV9TRUMiIF0gJiYgWyAkKChVUCAtIGhsX3RyeV9hdCkp
IC1nZSAiJFZJREVPX0dPTkVfU0VDIiBdIHx8IHJldHVybiAwCiAgaGxfdHJ5X2F0PSRVUAogIGRv
X3JlYm9vdCAidmlkZW8gYWJzZW50ZSAoaGxjYW1kKSBkZXB1aXMgJF9kIHMiCiAgcmV0dXJuIDAK
fQoKIyBCb2l0ZSBub2lyZSBkZSBsJ2VucXVldGUgU1NIICh2NykgOiByZWxhbmNlZSBzaSBlbGxl
IGVzdCBpbnN0YWxsZWUgKCRRUC9iYi5zaCkgZXQgYWN0aXZlZSAoJFFQL2JiLm9uKSwgeSBjb21w
cmlzIGFwcmVzCiMgdW4gcmVkZW1hcnJhZ2UgOyA0IGxhbmNlbWVudHMgcGFyIGhldXJlIGF1IHBs
dXMuIEVsbGUgbmUgdml0IHF1J2VuIG1lbW9pcmUgdml2ZSAoam91cm5hbCAvdG1wL2JiLmxvZyBw
bGFmb25uZSBhIH4yIE1vKS4KQkI9b2ZmCkJCUElEPSR7UVBfQkJfUElEOi0vdG1wL2JiLnBpZH0K
QkJMT0c9JHtRUF9CQl9MT0c6LS90bXAvYmIubG9nfQpiYl9jaGVjaygpIHsKICBbIC1mICIkUVAv
YmIub24iIF0gJiYgWyAtcyAiJFFQL2JiLnNoIiBdIHx8IHsgQkI9b2ZmOyByZXR1cm4gMDsgfQog
IHJkIF9iYnAgIiRCQlBJRCIgMDsgdG9pbnQgX2JicCAwCiAgaWYgWyAiJF9iYnAiICE9IDAgXSAm
JiBraWxsIC0wICIkX2JicCIgMj4vZGV2L251bGwgJiYgZ3JlcCAtcSBiYi5zaCAiL3Byb2MvJF9i
YnAvY21kbGluZSIgMj4vZGV2L251bGw7IHRoZW4gQkI9MTsgcmV0dXJuIDA7IGZpCiAgQkI9MAog
IHBhc3NpdmUgImxhbmNlbWVudCBkZSBsYSBib2l0ZSBub2lyZSIgJiYgcmV0dXJuIDAKICByYXRl
X29rIGJic3RhcnQgNCAzNjAwIHx8IHJldHVybiAwCiAgbG9nICJib2l0ZSBub2lyZSBhYnNlbnRl
IDogbGFuY2VtZW50IgogICggc2V0c2lkIG5vaHVwIHNoICIkUVAvYmIuc2giID4vZGV2L251bGwg
Mj4mMSA8IC9kZXYvbnVsbCAmICkKICBCQj0xCn0KIyBFY2hhbnRpbGxvbnMgZGUgbGEgZGV0ZWN0
aW9uIGRlIHBlcnNvbm5lcyBpbnRlcm5lICgvdG1wL3Zpc2lvbi5zYW1wbGVzLCAyLDQgTW8gZGUg
bWVtb2lyZSB2aXZlKSA6IGNyZWVzIGF1IGRlbWFycmFnZSBwYXIKIyBsZSBwcmVtaWVyIGxhbmNl
bWVudCBkZSBobGNhbWQgKHJlZ2xhZ2VzIGR1IGNvbnN0cnVjdGV1cikgZXQgaW51dGlsZXMgdW5l
IGZvaXMgbGEgdmlkZW8gcmVsYW5jZWUgc2FucyBjZXR0ZSBkZXRlY3Rpb24uCiMgUmV0aXJlcyBz
ZXVsZW1lbnQgc2kgbGEgZGV0ZWN0aW9uIGVzdCBjb3VwZWUgZGVwdWlzIDUgbWluIGV0IHF1J2F1
Y3VuIHByb2Nlc3N1cyBuZSBsZXMgb3V2cmUgbmkgbmUgbGVzIHByb2pldHRlLgpTQU1QTEVTPSR7
UVBfU0FNUExFUzotL3RtcC92aXNpb24uc2FtcGxlc30KU0FNUExFU19BRlRFUj0kKGludCAiJHtR
UF9TQU1QTEVTX0FGVEVSOi0zMDB9IiAzMDApCml2X29mZl9zaW5jZT0wCnNhbXBsZXNfY2hlY2so
KSB7CiAgaWYgWyAiJFZfaXYiICE9IDAgXSB8fCBbIC16ICIkVl9waWQiIF07IHRoZW4gaXZfb2Zm
X3NpbmNlPTA7IHJldHVybiAwOyBmaQogIFsgIiRpdl9vZmZfc2luY2UiID0gMCBdICYmIGl2X29m
Zl9zaW5jZT0kVVAKICBbIC1mICIkU0FNUExFUyIgXSAmJiBbICQoKFVQIC0gaXZfb2ZmX3NpbmNl
KSkgLWdlICIkU0FNUExFU19BRlRFUiIgXSB8fCByZXR1cm4gMAogIGxzIC1sIC9wcm9jL1swLTld
Ki9mZCAyPi9kZXYvbnVsbCB8IGdyZXAgLXEgIiR7U0FNUExFUyMjKi99IiAmJiByZXR1cm4gMAog
IGdyZXAgLXEgIiR7U0FNUExFUyMjKi99IiAvcHJvYy9bMC05XSovbWFwcyAyPi9kZXYvbnVsbCAm
JiByZXR1cm4gMAogIHBhc3NpdmUgInJldHJhaXQgZGUgJFNBTVBMRVMiICYmIHJldHVybiAwCiAg
X2s9JCgoICQod2MgLWMgPCAiJFNBTVBMRVMiIDI+L2Rldi9udWxsIHx8IGVjaG8gMCkgLyAxMDI0
ICkpCiAgcm0gLWYgIiRTQU1QTEVTIiAmJiBsb2cgImRldGVjdGlvbiBpbnRlcm5lIGNvdXBlZSA6
ICRTQU1QTEVTIHJldGlyZSAoJHtfa30gS2lvIGRlIG1lbW9pcmUgcmVuZHVzKSIKfQoKIyAtLS0g
ZXRhdCBkZSBsYSBib3VjbGUgKGluc3RhbnRzIGVuIHNlY29uZGVzIGQndXB0aW1lLCAwID0gcmll
biBlbiBjb3VycykgLS0tCmRlYWRfc2luY2U9MDsgbWVtX2xvd19zaW5jZT0wOyBtcV9kb3duX3Np
bmNlPTA7IG5ldF9kb3duX3NpbmNlPTA7IGhhbmdfa2lsbHM9MDsgbDE9MDsgbDI9MDsgbDNfYXQ9
LTk5OTk5OQpsYXN0X25ldD0tOTk5OTk5OyBsYXN0X3Nsb3c9LTk5OTk5OTsgbmV0X29rPTE7IEdX
PTsgZ3dfYXQ9LTk5OTk5OTsgaGxfZ29uZV9zaW5jZT0tMTsgaGxfdHJ5X2F0PS05OTk5OTkKVl9w
aWQ9OyBWX2l2PT87IFZfcmF0ZT0/OyBWX2dvcD0/OyBWX3NoaW09PzsgVl9jb2RlYz0/OyBMMjI9
PzsgTDIyMjI9PzsgRkQ9PzsgRk09Pwpfb209Im9yZHJlcyBIQSBkZSByZWRlbWFycmFnZSBzYW5z
IGxpbWl0ZSAodjEwKSI7IFsgIiRPUkRFUl9SRUJPT1RfTUFYIiAtZ3QgMCBdICYmIF9vbT0ib3Jk
cmVzIEhBIGRlIHJlZGVtYXJyYWdlIDogJE9SREVSX1JFQk9PVF9NQVggcGFyICQoKFJFQk9PVF9X
SU5ET1cvMzYwMCkpIGggYXUgcGx1cyIKbG9nICJzdXJ2ZWlsbGFudCBkZW1hcnJlIChwaWQgJCQp
IDsgJF9vbSIKCndoaWxlIDo7IGRvCiAgdXBfbm93CiAgZWNobyAiJFVQIiA+ICIkUlVOL2d1YXJk
X2JlYXQiCgogICMgKDUpIG9yZHJlcyBkZSBIb21lIEFzc2lzdGFudAogIGZvciBjIGluICIkQ01E
Ii8qOyBkbwogICAgWyAtZSAiJGMiIF0gfHwgY29udGludWUKICAgIG49JHtjIyMqL30KICAgIFsg
LWYgIiRjIiBdIHx8IHsgcm0gLXJmICIkYyI7IGxvZyAib3JkcmUgaWdub3JlIChwYXMgdW4gZmlj
aGllcikgOiAkbiI7IGNvbnRpbnVlOyB9ICAgICAjIHY2CiAgICBybSAtZiAiJGMiCiAgICBjYXNl
ICIkbiIgaW4KICAgICAgcmVzdGFydC1hcHApICAgICByYXRlX29rIG9yZGVyX3Jlc3RhcnQgNiAz
NjAwIHx8IHsgbG9nICJvcmRyZSBIQSByZWZ1c2UgKDYgcmVsYW5jZXMgcGFyIGhldXJlIGF1IHBs
dXMpIDogJG4iOyBjb250aW51ZTsgfQogICAgICAgICAgICAgICAgICAgICAgIGxvZyAib3JkcmUg
SEEgOiByZWxhbmNlIGRlIGwnYXBwbGljYXRpb24iOyBzdG9wX2NoaWxkIDs7CiAgICAgIHdpZmkt
Ym91bmNlKSAgICAgcmF0ZV9vayBvcmRlcl93aWZpIDYgMzYwMCB8fCB7IGxvZyAib3JkcmUgSEEg
cmVmdXNlICg2IG9yZHJlcyBXaS1GaSBwYXIgaGV1cmUgYXUgcGx1cykgOiAkbiI7IGNvbnRpbnVl
OyB9CiAgICAgICAgICAgICAgICAgICAgICAgbG9nICJvcmRyZSBIQSA6IFdpLUZpIjsgd2lmaV9s
MSAib3JkcmUgSEEiIDs7CiAgICAgIHdpZmktZHJpdmVyKSAgICAgcmF0ZV9vayBvcmRlcl93aWZp
IDYgMzYwMCB8fCB7IGxvZyAib3JkcmUgSEEgcmVmdXNlICg2IG9yZHJlcyBXaS1GaSBwYXIgaGV1
cmUgYXUgcGx1cykgOiAkbiI7IGNvbnRpbnVlOyB9CiAgICAgICAgICAgICAgICAgICAgICAgbG9n
ICJvcmRyZSBIQSA6IHBpbG90ZSBXaS1GaSI7IHdpZmlfbDIgIm9yZHJlIEhBIiA7OwogICAgICBz
c2gtcmVzdGFydCkgICAgIHJhdGVfb2sgb3JkZXJfc3NoIDYgMzYwMCB8fCB7IGxvZyAib3JkcmUg
SEEgcmVmdXNlICg2IHJlbGFuY2VzIFNTSCBwYXIgaGV1cmUgYXUgcGx1cykgOiAkbiI7IGNvbnRp
bnVlOyB9ICAgICAjIHY4CiAgICAgICAgICAgICAgICAgICAgICAgbG9nICJvcmRyZSBIQSA6IHJl
bGFuY2UgU1NIIjsgc3NoX3Jlc3RhcnQgIm9yZHJlIEhBIiA7OwogICAgICByZWJvb3QpICAgICAg
ICAgIGRvX3JlYm9vdCAib3JkcmUgSEEiIDs7CiAgICAgIHJlYm9vdC1pbnN0YWxsYXRpb24pIGRv
X3JlYm9vdCAib3JkcmUgSEEgKGZpbiBkJ2luc3RhbGxhdGlvbiBPcGVuUUlBUkEgQ2xhdWRlIFYx
NSkiIDs7CiAgICAgIHJlYm9vdC1yZWdsYWdlKSAgZG9fcmVib290ICJvcmRyZSBIQSAoY2hhbmdl
bWVudCBkZSByZWdsYWdlIHZpZGVvLCByZWdsYWdlLnNoKSIgOzsKICAgICAgdXBkYXRlLXJvbGxi
YWNrKSBwYXNzaXZlICJyZXRvdXIgYXJyaWVyZSIgfHwgc2ggIiRRUC9xcC11cGRhdGUiIHJvbGxi
YWNrICJvcmRyZSBIQSIgPj4gIiRMT0ciIDI+JjEgOzsKICAgICAgdXBkYXRlLXByb21vdGUpICBw
YXNzaXZlICJ2YWxpZGF0aW9uIiB8fCBzaCAiJFFQL3FwLXVwZGF0ZSIgcHJvbW90ZSAtLWZvcmNl
ID4+ICIkTE9HIiAyPiYxIDs7CiAgICAgIHVzZS1wcmV2KSAgICAgICAgcmF0ZV9vayBvcmRlcl9y
ZXN0YXJ0IDYgMzYwMCB8fCB7IGxvZyAib3JkcmUgSEEgcmVmdXNlICg2IHJlbGFuY2VzIHBhciBo
ZXVyZSBhdSBwbHVzKSA6ICRuIjsgY29udGludWU7IH0gICAgICMgdjYKICAgICAgICAgICAgICAg
ICAgICAgICBwYXNzaXZlICJyZXRvdXIgYSBsYSB2ZXJzaW9uIHByZWNlZGVudGUiIHx8IHNoICIk
UVAvcXAtdXBkYXRlIiB1c2UtcHJldiA+PiAiJExPRyIgMj4mMSA7OwogICAgICAqKSAgICAgICAg
ICAgICAgIGxvZyAib3JkcmUgaW5jb25udSBpZ25vcmUgOiAkbiIgOzsKICAgIGVzYWMKICBkb25l
CgogICMgKDEpIGV0ICgyKSBsJ2FwcGxpY2F0aW9uCiAgaHY9MAogIGlmIGNoaWxkX2FsaXZlOyB0
aGVuCiAgICBkZWFkX3NpbmNlPTAKICAgIHJkIHJzICIkU1QvcnVuX3VwIiAwOyByZCByYiAiJFNU
L3J1bl9ib290IiAiIjsgcmQgcnNsICIkU1QvcnVubmluZ19zbG90IiBub25lOyBib290X2lkCiAg
ICB0b2ludCBycyAwOyBpZiBbICIkcmIiID0gIiRCT09UIiBdOyB0aGVuIGFnZT0kKCggVVAgLSBy
cyApKTsgZWxzZSBhZ2U9MDsgZmkKICAgICMgc2FudGUgdmFsYWJsZSBzZXVsZW1lbnQgc2kgZWxs
ZSBhIGV0ZSBlY3JpdGUgcGVuZGFudCBDRSBsYW5jZW1lbnQgKHVuZSB2ZXJzaW9uIHNhbnMgZmlj
aGllciBkZSBzYW50ZQogICAgIyBsYW5jZWUgYXByZXMgdW5lIHZlcnNpb24gcXVpIGVuIGVjcml2
YWl0IG5lIGRvaXQgamFtYWlzIGV0cmUganVnZWUgc3VyIGwnYW5jaWVuIGZpY2hpZXIpCiAgICBp
ZiBoZWFsdGhfcmVhZDsgdGhlbiB0b2ludCBIX3VwIDA7IFsgIiRyYiIgPSAiJEJPT1QiIF0gJiYg
WyAiJEhfdXAiIC1nZSAiJHJzIiBdICYmIGh2PTE7IGZpCiAgICBpZiBbICIkaHYiID0gMSBdOyB0
aGVuCiAgICAgIGhlYWx0aF9hZ2UKICAgICAgWyAiJEhfYWdlIiAtbHQgNjAgXSAmJiBbICIkSF9v
ayIgPSAxIF0gJiYgbm90ZV9oZWFsdGggIiRyc2wiCiAgICAgIGlmIFsgIiRhZ2UiIC1nZSAiJEhF
QUxUSF9HUkFDRSIgXSAmJiBbICIkSF9hZ2UiIC1ndCAiJEhFQUxUSF9TVEFMRSIgXTsgdGhlbgog
ICAgICAgIGhhbmdfa2lsbCAic2FudGUgdmllaWxsZSBkZSAke0hfYWdlfSBzIgogICAgICBlbGlm
IFsgLWUgIiRTVC90cmlhbCIgXSAmJiBbICIkcnNsIiA9IG5ldyBdICYmIFsgIiRhZ2UiIC1nZSAi
JFBST01PVEVfQUZURVIiIF0gJiYgWyAiJEhfYWdlIiAtbHQgNjAgXSAmJiBbICIkSF9vayIgPSAx
IF0gJiYgWyAiJHtIX21xdHQ6LTF9IiAhPSAwIF07IHRoZW4KICAgICAgICBzaCAiJFFQL3FwLXVw
ZGF0ZSIgcHJvbW90ZSA+PiAiJExPRyIgMj4mMTsgaGFuZ19raWxscz0wICAgICAgIyB2YWxpZGF0
aW9uIDogc2FudGUgYm9ubmUgRVQgbGlhaXNvbiBNUVRUIGFjdGl2ZQogICAgICBmaQogICAgZWxp
ZiBbICIkYWdlIiAtZ2UgIiRIRUFMVEhfR1JBQ0UiIF0gJiYgeyB7IFsgLWUgIiRTVC90cmlhbCIg
XSAmJiBbICIkcnNsIiA9IG5ldyBdOyB9IHx8IHNlZW5faGVhbHRoICIkcnNsIjsgfTsgdGhlbgog
ICAgICBoYW5nX2tpbGwgImF1Y3VuZSBzYW50ZSAke2FnZX0gcyBhcHJlcyBsZSBsYW5jZW1lbnQi
ICAgICAgICMgZXNzYWksIG91IHZlcnNpb24gcXVpIGVjcml2YWl0IHNhIHNhbnRlCiAgICBmaQog
IGVsc2UKICAgIFsgIiRkZWFkX3NpbmNlIiA9IDAgXSAmJiBkZWFkX3NpbmNlPSRVUAogICAgaWYg
WyAkKChVUCAtIGRlYWRfc2luY2UpKSAtZ2UgIiRERUFEX1NFQyIgXTsgdGhlbgogICAgICBpZiAh
IGlzX2xhdW5jaGVyOyB0aGVuCiAgICAgICAgbG9nICJhcHBsaWNhdGlvbiBub24gc3VpdmllIGV0
ICRMQVVOQ0hFUiBuJ2VzdCBwbHVzIGxlIGxhbmNldXIgKG1pc2UgYSBqb3VyIHBhciBsJ2ludGVy
ZmFjZSA/KSA6IGF1Y3VuIGxhbmNlbWVudCIKICAgICAgZWxzZSBwYXNzaXZlICJsYW5jZW1lbnQg
ZGUgbCdhcHBsaWNhdGlvbiIgfHwgewogICAgICAgIGxvZyAiYXBwbGljYXRpb24gYWJzZW50ZSBk
ZXB1aXMgJHtERUFEX1NFQ30gcyA6IGxhbmNlbWVudCBwYXIgbGUgc3VydmVpbGxhbnQiCiAgICAg
ICAgKCBub2h1cCAiJExBVU5DSEVSIiAtd2ViIDo4MCAtbG9nIC9kYXRhL29wZW5xaWFyYWQubG9n
ID4vZGV2L251bGwgMj4mMSAmICk7IH0KICAgICAgZmkKICAgICAgZGVhZF9zaW5jZT0wCiAgICBm
aQogIGZpCgogICMgbWVtb2lyZSBkaXNwb25pYmxlCiAgbWVtX2F2YWlsCiAgaWYgWyAiJE1BIiAt
Z3QgMCBdICYmIFsgIiRNQSIgLWx0ICIkTUVNX01JTl9LQiIgXTsgdGhlbgogICAgWyAiJG1lbV9s
b3dfc2luY2UiID0gMCBdICYmIG1lbV9sb3dfc2luY2U9JFVQCiAgICBpZiBbICQoKFVQIC0gbWVt
X2xvd19zaW5jZSkpIC1nZSAiJE1FTV9MT1dfU0VDIiBdOyB0aGVuCiAgICAgIGlmIHJhdGVfb2sg
bWVtcmVzdGFydCAyIDM2MDA7IHRoZW4gbG9nICJtZW1vaXJlIGRpc3BvbmlibGUgYmFzc2UgKCR7
TUF9IEtpbykgZGVwdWlzICRNRU1fTE9XX1NFQyBzIDogcmVsYW5jZSBkZSBsJ2FwcGxpY2F0aW9u
Ijsgc3RvcF9jaGlsZDsgZmkKICAgICAgbWVtX2xvd19zaW5jZT0wCiAgICBmaQogIGVsc2UgbWVt
X2xvd19zaW5jZT0wOyBmaQoKICAjICg0KSByZXNlYXUKICBpdj0kTkVUX0NIRUNLX1NFQzsgWyAi
JG5ldF9vayIgPSAwIF0gJiYgaXY9JFRJQ0sKICBpZiBbICQoKFVQIC0gbGFzdF9uZXQpKSAtZ2Ug
IiRpdiIgXTsgdGhlbgogICAgbGFzdF9uZXQ9JFVQCiAgICBbICQoKFVQIC0gZ3dfYXQpKSAtZ2Ug
NjAwIF0gfHwgWyAteiAiJEdXIiBdICYmIHsgZ2F0ZXdheTsgZ3dfYXQ9JFVQOyB9CiAgICBpZiBb
IC1uICIkR1ciIF0gJiYgcGluZyAtYyAxIC1XIDIgIiRHVyIgPi9kZXYvbnVsbCAyPiYxOyB0aGVu
CiAgICAgIGlmIFsgIiRuZXRfb2siID0gMCBdOyB0aGVuCiAgICAgICAgbG9nICJwYXNzZXJlbGxl
IGRlIG5vdXZlYXUgam9pZ25hYmxlIGFwcmVzICQoKFVQIC0gbmV0X2Rvd25fc2luY2UpKSBzIgog
ICAgICAgIFsgJCgoVVAgLSBuZXRfZG93bl9zaW5jZSkpIC1nZSAiJElOQ0lERU5UX01JTl9TRUMi
IF0gJiYgc25hcHNob3QgImNvdXB1cmUgZGUgJCgoVVAgLSBuZXRfZG93bl9zaW5jZSkpIHMgdGVy
bWluZWUiCiAgICAgIGZpCiAgICAgIG5ldF9vaz0xOyBuZXRfZG93bl9zaW5jZT0wOyBsMT0wOyBs
Mj0wOyBsM19hdD0tOTk5OTk5CiAgICBlbHNlCiAgICAgIFsgIiRuZXRfb2siID0gMSBdICYmIHsg
bmV0X2Rvd25fc2luY2U9JFVQOyBsb2cgInBhc3NlcmVsbGUgJHtHVzotaW5jb25udWV9IG11ZXR0
ZSI7IH0KICAgICAgbmV0X29rPTA7IGQ9JCgoVVAgLSBuZXRfZG93bl9zaW5jZSkpCiAgICAgICMg
djYgOiB1biByZWRlbWFycmFnZSByZWZ1c2UgKHBsYWZvbmQsIGRlc2FjdGl2ZSwgcGFzc2lmKSBu
J2VzdCByZXRlbnRlIHF1J2FwcmVzIE5FVF9MM19TRUMsIGF1IGxpZXUgZGUgY2hhcXVlIHRvdXIg
KGpvdXJuYWwpCiAgICAgIGlmIFsgIiRkIiAtZ2UgIiRORVRfTDNfU0VDIiBdOyB0aGVuIFsgJCgo
VVAgLSBsM19hdCkpIC1nZSAiJE5FVF9MM19TRUMiIF0gJiYgeyBsM19hdD0kVVA7IGRvX3JlYm9v
dCAicGFzc2VyZWxsZSBtdWV0dGUgZGVwdWlzICRkIHMiICYmIG5ldF9kb3duX3NpbmNlPSRVUDsg
fQogICAgICBlbGlmIFsgIiRkIiAtZ2UgIiRORVRfTDJfU0VDIiBdICYmIFsgIiRsMiIgPSAwIF07
IHRoZW4gc25hcHNob3QgInBhc3NlcmVsbGUgbXVldHRlIGRlcHVpcyAkZCBzIjsgd2lmaV9sMiAi
cGFzc2VyZWxsZSBtdWV0dGUgZGVwdWlzICRkIHMiOyBsMj0xCiAgICAgIGVsaWYgWyAiJGQiIC1n
ZSAiJE5FVF9MMV9TRUMiIF0gJiYgWyAiJGwxIiA9IDAgXTsgdGhlbiB3aWZpX2wxICJwYXNzZXJl
bGxlIG11ZXR0ZSBkZXB1aXMgJGQgcyI7IGwxPTEKICAgICAgZmkKICAgIGZpCiAgZmkKICAjIE1R
VFQgY291cGUgYWxvcnMgcXVlIGxlIHJlc2VhdSB2YSBiaWVuIEVUIHF1ZSBsZSBzZXJ2ZXVyIE1R
VFQgYWNjZXB0ZSBsZXMgY29ubmV4aW9ucyA6IHByb2JsZW1lIGRlIGwnYXBwbGljYXRpb24KICAj
IChIb21lIEFzc2lzdGFudCBhcnJldGUgb3UgaW5qb2lnbmFibGUgOiBhdWN1bmUgcmVsYW5jZSwg
ZWxsZSBuZSBzZXJ2aXJhaXQgYSByaWVuKQogIGlmIFsgIiRuZXRfb2siID0gMSBdICYmIFsgIiRo
diIgPSAxIF0gJiYgWyAiJEhfYWdlIiAtbHQgNjAgXSAmJiBbICIkSF9tcXR0IiA9IDAgXSAmJiBb
ICIkSF9icm9rZXIiID0gMSBdOyB0aGVuCiAgICBbICIkbXFfZG93bl9zaW5jZSIgPSAwIF0gJiYg
bXFfZG93bl9zaW5jZT0kVVAKICAgIGlmIFsgJCgoVVAgLSBtcV9kb3duX3NpbmNlKSkgLWdlICIk
TVFUVF9SRVNUQVJUX1NFQyIgXTsgdGhlbgogICAgICBpZiByYXRlX29rIG1xdHRyZXN0YXJ0IDIg
MzYwMDsgdGhlbgogICAgICAgIGxvZyAiTVFUVCBjb3VwZSBkZXB1aXMgJCgoVVAgLSBtcV9kb3du
X3NpbmNlKSkgcyBhbG9ycyBxdWUgbGUgc2VydmV1ciByZXBvbmQgOiByZWxhbmNlIGRlIGwnYXBw
bGljYXRpb24iOyBzdG9wX2NoaWxkCiAgICAgIGVsc2UgbG9nICJNUVRUIGNvdXBlIGRlcHVpcyAk
KChVUCAtIG1xX2Rvd25fc2luY2UpKSBzIDogZGVqYSAyIHJlbGFuY2VzIGVuIDEgaCwgcmllbiBk
ZSBwbHVzIjsgZmkKICAgICAgbXFfZG93bl9zaW5jZT0wCiAgICBmaQogIGVsc2UgbXFfZG93bl9z
aW5jZT0wOyBmaQoKICAjICgzKSBldCAoNikgY29udHJvbGVzIGVzcGFjZXMKICBpZiBbICQoKFVQ
IC0gbGFzdF9zbG93KSkgLWdlICIkU0xPV19TRUMiIF07IHRoZW4KICAgIGxhc3Rfc2xvdz0kVVAK
ICAgIGxpc3RlbmluZwogICAgWyAiJEwyMjIyIiA9IDAgXSAmJiB7IHBhc3NpdmUgInJlbGFuY2Ug
ZHUgU1NIIGRlIHNlY291cnMiIHx8IHsgbG9nICJTU0ggZGUgc2Vjb3VycyAocG9ydCAkU1NIX1NF
Q09VUlNfUE9SVCkgYWJzZW50IDogcmVsYW5jZSI7IHN0YXJ0X2Ryb3BiZWFyXzIyMjI7IH07IH0K
ICAgIFsgIiRMMjIiID0gMSBdIHx8IHBhc3NpdmUgInJlbGFuY2UgZGUgZHJvcGJlYXIgMjIiIHx8
IHsgbG9nICJkcm9wYmVhciAyMiBhYnNlbnQgOiByZWxhbmNlIjsgYm91bmRlZCAyMCBmYnh1cHN0
YXJ0Y3RsIHN0YXJ0IGRyb3BiZWFyOyB9CiAgICBGRD0kKGZyZWVfa2IgL2RhdGEpCiAgICBGTT0k
KGZyZWVfa2IgIiR7UVBfTUVESUFfREY6LS9tZWRpYX0iKSAgICMgdjYgOiAvbWVkaWEgKGluY2lk
ZW50IGR1IDI2LzEwIGEgOTIgJSkKICAgIGlmIFsgLW4gIiRGRCIgXSAmJiBbICIkRkQiIC1sdCAx
NTAwIF0gJiYgISBwYXNzaXZlICJ2aWRhZ2UgZGVzIGpvdXJuYXV4IjsgdGhlbgogICAgICBsb2cg
InBsYWNlIHN1ciAvZGF0YSBiYXNzZSAoJHtGRH0gS2lvKSA6IGpvdXJuYXV4IHZpZGVzIgogICAg
ICBmb3IgZiBpbiAvZGF0YS9obGNhbWQubG9nIC9kYXRhL2Ruc21hc3EubG9nIC9kYXRhL3Bvc3Rf
Ym9vdC5sb2cgL2RhdGEvYm9vdF9kZWJ1Zy5sb2c7IGRvIFsgLWYgIiRmIiBdICYmIHRydWUgMj4v
ZGV2L251bGwgPiAiJGYiOyBkb25lCiAgICBmaQogICAgdmlkZW9fY2hlY2s7IHZpZGVvX2dvbmVf
Y2hlY2sKICAgIHJkIHJzbCAiJFNUL3J1bm5pbmdfc2xvdCIgbm9uZTsgbGFzdF9yZXN1bHQ7IHVy
ZXM9JF9scjsgcmQgbHJiICIkU1QvbGFzdF9yZWJvb3RfcmVhc29uIiBhdWN1bgogICAgYmJfY2hl
Y2s7IHNhbXBsZXNfY2hlY2sKICAgIHsKICAgICAgZWNobyAidHM9JChub3cpIjsgZWNobyAidXA9
JFVQIgogICAgICBlY2hvICJuZXRfb2s9JG5ldF9vayI7IGVjaG8gIm5ldF9kb3duX3M9JChbICIk
bmV0X29rIiA9IDAgXSAmJiBlY2hvICQoKFVQIC0gbmV0X2Rvd25fc2luY2UpKSB8fCBlY2hvIDAp
IgogICAgICBlY2hvICJtZW1fYXZhaWxfa2I9JE1BIjsgZWNobyAiZGF0YV9mcmVlX2tiPSR7RkQ6
LT99IjsgZWNobyAibWVkaWFfZnJlZV9rYj0ke0ZNOi0/fSIKICAgICAgZWNobyAic3NoMjI9JEwy
MiI7IGVjaG8gInNzaDIyMjI9JEwyMjIyIgogICAgICBlY2hvICJoYW5nX2tpbGxzPSRoYW5nX2tp
bGxzIjsgZWNobyAic2xvdD0kcnNsIjsgZWNobyAidHJpYWw9JChbIC1lICIkU1QvdHJpYWwiIF0g
JiYgZWNobyAxIHx8IGVjaG8gMCkiCiAgICAgIGVjaG8gInVwZGF0ZV9yZXN1bHQ9JHVyZXMiOyBl
Y2hvICJsYXN0X3JlYm9vdD0kbHJiIgogICAgICBlY2hvICJ2aWRlb19pdj0kVl9pdiI7IGVjaG8g
InZpZGVvX2JpdHJhdGU9JFZfcmF0ZSI7IGVjaG8gInZpZGVvX2dvcF9kZW51bT0kVl9nb3AiOyBl
Y2hvICJ2aWRlb19zaGltPSRWX3NoaW0iOyBlY2hvICJ2aWRlb19jb2RlYz0kVl9jb2RlYyIKICAg
ICAgZWNobyAibGF1bmNoZXJfb2s9JChpc19sYXVuY2hlciAmJiBlY2hvIDEgfHwgZWNobyAwKSIK
ICAgICAgZWNobyAiYmI9JEJCIgogICAgfSA+ICIkU1RBVFVTLnRtcCIgMj4vZGV2L251bGwgJiYg
bXYgLWYgIiRTVEFUVVMudG1wIiAiJFNUQVRVUyIKICBmaQoKICBbIC1uICIkUVBfT05DRSIgXSAm
JiB7IFsgIiRRUF9PTkNFIiAtbGUgMSBdICYmIGV4aXQgMDsgUVBfT05DRT0kKChRUF9PTkNFIC0g
MSkpOyB9CiAgc2xlZXAgIiRUSUNLIgpkb25lCg==
@@FILE qp-update a86c2a7e57e476f67e8f8f4bea693b9f542ad662dfe81a65a0b2da03f7f92d77
IyEvYmluL3NoCiMgcXAtdXBkYXRlIDogaW5zdGFsbGF0aW9uLCBlc3NhaSwgdmFsaWRhdGlvbiBl
dCByZXRvdXIgYXJyaWVyZSBkZXMgYmluYWlyZXMgT3BlblFpYXJhIChDbGF1ZGUsIDI2LzEwLzIw
MjYgOyB2NiAyNy8xMCA6CiMgcGFzIGRlIGRlcG90IHBlbmRhbnQgdW4gZXNzYWkgZW4gY291cnMs
IHZhbGlkYXRpb24gcmVmdXNlZSBzaSBsZSBiaW5haXJlIGRlIG5ldyBuJ2VzdCBwYXMgY2VsdWkg
cXVpIHRvdXJuZSwgdXNlLXByZXYgaWRlbXBvdGVudCkuCiMgVXNhZ2UgOiBxcC11cGRhdGUgdXNl
LXByZXYgICAgICAgICAgICAgICAgIHJldmllbnQgYSBsYSB2ZXJzaW9uIHZhbGlkZWUgcHJlY2Vk
ZW50ZSAocHJldikKIyAgICAgICAgIHFwLXVwZGF0ZSBzdGFnZSBGSUNISUVSIFtTSEEyNTZdICAg
ZGVwb3NlIEZJQ0hJRVIgZGFucyBsJ2VtcGxhY2VtZW50IG5ldyBldCBsYW5jZSB1biBlc3NhaSBh
dSBwcm9jaGFpbiBkZW1hcnJhZ2UKIyAgICAgICAgIHFwLXVwZGF0ZSBwcm9tb3RlICAgICAgICAg
ICAgICAgICAgY29waWUgbmV3IGRhbnMgZ29vZCAobCdlc3NhaSBlc3QgcmV1c3NpKQojICAgICAg
ICAgcXAtdXBkYXRlIHJvbGxiYWNrICAgICAgICAgICAgICAgICBhYmFuZG9ubmUgbCdlc3NhaSA6
IG5ldyBlc3QgZWNhcnRlLCByZXRvdXIgYSBnb29kCiMgICAgICAgICBxcC11cGRhdGUgc2VlZC1m
YWN0b3J5IEZJQ0hJRVIgICAgIGluc3RhbGxlIGxlIGJpbmFpcmUgZCdvcmlnaW5lICh1bmUgc2V1
bGUgZm9pcywgcGFyIGwnaW5zdGFsbGF0aW9uKQojICAgICAgICAgcXAtdXBkYXRlIHNlZWQtZ29v
ZCBGSUNISUVSICAgICAgICBpbnN0YWxsZSBsZSBiaW5haXJlIGRlIHJlZmVyZW5jZSBjb3VyYW50
IChwYXIgbCdpbnN0YWxsYXRpb24pCiMgICAgICAgICBxcC11cGRhdGUgc3RhdHVzICAgICAgICAg
ICAgICAgICAgIGV0YXQgbGlzaWJsZSAoYXVzc2kgZWNyaXQgZGFucyAkUlVOL3N0YXR1cy11cGRh
dGUpClFQX1dITz1xcC11cGRhdGUKUVA9JHtRUDotL2RhdGEvcXB9CiMgY29tbW9uLnNoIC0gZm9u
Y3Rpb25zIGNvbW11bmVzIGRlIMKrIFFpYXJhIFBsdXMgwrsgKENsYXVkZSwgMjYvMTAvMjAyNiwg
djIgOiBlY29ub21lIGVuIG1lbW9pcmUgZXQgZW4gcHJvY2Vzc3VzIDsKIyB2NiAyNy8xMC8yMDI2
IDogYWdlcyBtZXN1cmVzIHN1ciBsJ3VwdGltZSBldCBsZSBudW1lcm8gZGUgZGVtYXJyYWdlLCBq
YW1haXMgc3VyIGxhIHNldWxlIGhvcmxvZ2UgbXVyYWxlKQojIFNoZWxsIDogYnVzeWJveCBhc2gg
ZGUgbGEgY2FtZXJhLiBSaWVuIGljaSBuZSBkb2l0IHN1cHBvc2VyIGJhc2guCiMgTGVzIGR1cmVl
cyBzZSBtZXN1cmVudCBzdXIgL3Byb2MvdXB0aW1lIChtb25vdG9uZSkgOiBsJ2hvcmxvZ2UgbXVy
YWxlIGRlbWFycmUgZW4gMTk3MCBldCBzYXV0ZSBhdSByZWdsYWdlIE5UUC4KUVA9JHtRUDotL2Rh
dGEvcXB9ICAgICAgICAgICAgICAgICAjIHBldGl0IDogZXRhdCwgYmluYWlyZSBkJ29yaWdpbmUg
KGNhcnRlIC9kYXRhLCAyMCBNaW8pCkJVTEs9JHtRUF9CVUxLOi0vbWVkaWEvcXB9ICAgICAgICAg
IyBncm9zIDogZW1wbGFjZW1lbnRzIGdvb2QgZXQgbmV3IChjYXJ0ZSAvbWVkaWEsIDIsOCBHbykK
UlVOPSR7UVBfUlVOOi0vdG1wL3FwfSAgICAgICAgICAgICAjIG1lbW9pcmUgdml2ZSA6IHNhbnRl
LCBvcmRyZXMsIGV0YXQgZGVzIGVzc2FpcwpTVD0kUVAvc3RhdGUKTE9HPSR7UVBfTE9HOi0vZGF0
YS9vcGVucWlhcmFkLmxvZ30KT0xEPSR7UVBfT0xEOi0vbWVkaWEvb3BlbnFpYXJhZC5vbGR9ICAg
IyByZXBsaSB1bHRpbWUgZHUgbGFuY2V1ciAoZXQgZGUgcG9zdF9ib290LnNoIHNpIC9kYXRhL29w
ZW5xaWFyYWQgZGlzcGFyYWl0KSA7IHY2IDogcmFmcmFpY2hpIHBhciBwcm9tb3RlL3NlZWQtZ29v
ZCwgZW1wcmVpbnRlIGEgY290ZQpbIC1kICIkU1QiIF0gJiYgWyAtZCAiJFJVTiIgXSB8fCBta2Rp
ciAtcCAiJFNUIiAiJFJVTiIgMj4vZGV2L251bGwKCnRzKCkgeyBkYXRlICcrJVktJW0tJWRUJUg6
JU06JVMnOyB9Cm5vdygpIHsgZGF0ZSArJXM7IH0KbG9nKCkgeyBlY2hvICJbJHtRUF9XSE86LXFw
fV0gJCh0cykgJCoiID4+ICIkTE9HIiAyPi9kZXYvbnVsbDsgfQojIGxlY3R1cmUgZCd1bmUgbGln
bmUgc2FucyBwcm9jZXNzdXMgc3VwcGxlbWVudGFpcmUgOiByZCBWQVIgZmljaGllciBbZGVmYXV0
XQpyZCgpIHsgZXZhbCAiJDE9IiA7IFsgLXMgIiQyIiBdICYmIHsgcmVhZCAtciAiJDEiIDwgIiQy
IiB8fCA6OyB9OyBldmFsICJbIC1uIFwiXCQkMVwiIF0gfHwgJDE9XCR7My19IjsgfQp1cF9ub3co
KSB7IF91cHQ9MDsgcmVhZCAtciBfdXB0IF91cHIgPCAiJHtRUF9VUFRJTUU6LS9wcm9jL3VwdGlt
ZX0iIDI+L2Rldi9udWxsOyBVUD0ke191cHQlJS4qfTsgY2FzZSAiJFVQIiBpbiAnJ3wqWyEwLTld
KikgVVA9MDs7IGVzYWM7IH0gICAjIG1ldCBhIGpvdXIgJFVQIChzZWNvbmRlcyBkZXB1aXMgbGUg
ZGVtYXJyYWdlIDsgUVBfVVBUSU1FIDogYmFuYyBkJ2Vzc2FpKQpib290X2lkKCkgeyBpZiBbIC1u
ICIkUVBfQk9PVF9JRCIgXTsgdGhlbiBCT09UPSRRUF9CT09UX0lEOyBlbHNlIHJlYWQgLXIgQk9P
VCA8IC9wcm9jL3N5cy9rZXJuZWwvcmFuZG9tL2Jvb3RfaWQ7IGZpOyB9CiMgdjYgOiBudW1lcm8g
ZGUgZGVtYXJyYWdlLiAkU1QvYm9vdF9zZXEgPSAiYm9vdF9pZCBudW1lcm8iIDsgbGUgbGFuY2V1
ciBsJ2luY3JlbWVudGUgYSBjaGFxdWUgbm91dmVhdSBkZW1hcnJhZ2UgKGJvb3Rfc2VxX2J1bXAp
LAojIGxlcyBhdXRyZXMgbGUgbGlzZW50IChib290X3NlcV9ub3cgcG9zZSBTRVEsIGVuIGNvbXB0
YW50IDEgZGUgcGx1cyBzaSBsZSBmaWNoaWVyIHZpZW50IGQndW4gYXV0cmUgZGVtYXJyYWdlKS4g
SWwgcGVybWV0IGRlCiMgZmFpcmUgZXhwaXJlciwgYXByZXMgdW4gbm9tYnJlIGRlIGRlbWFycmFn
ZXMsIGNlIHF1aSBhIGV0ZSBkYXRlIGEgbCdob3Jsb2dlIGRlIDE5NzAgKHNhbnMgcmVzZWF1LCBs
J2hldXJlIG4nZXN0IHBhcyBmaWFibGUpLgpib290X3NlcV9ub3coKSB7IGJvb3RfaWQ7IF9zYj07
IF9zcz0wOyBbIC1zICIkU1QvYm9vdF9zZXEiIF0gJiYgcmVhZCAtciBfc2IgX3NzIDwgIiRTVC9i
b290X3NlcSIgMj4vZGV2L251bGw7IHRvaW50IF9zcyAwOyBTRVE9JF9zczsgWyAiJF9zYiIgPSAi
JEJPT1QiIF0gfHwgU0VRPSQoKF9zcyArIDEpKTsgfQpib290X3NlcV9idW1wKCkgeyBib290X3Nl
cV9ub3c7IFsgIiRfc2IiID0gIiRCT09UIiBdIHx8IHB1dCAiJFNUL2Jvb3Rfc2VxIiAiJEJPT1Qg
JFNFUSI7IH0KIyBFbnRpZXJzIHN1cnMgcG91ciAkKCggKSkgOiBlbiBtb2RlIFBPU0lYLCB1bmUg
ZXJyZXVyIGFyaXRobWV0aXF1ZSAoIjEyeCIsIG91ICIwOCIgbHUgZW4gb2N0YWwpIEFSUkVURSBs
ZSBzaGVsbC4KIyBTZXVscyBsZXMgY2hpZmZyZXMgc29udCBhY2NlcHRlcyA7IGxlcyB6ZXJvcyBk
ZSB0ZXRlIHNvbnQgcmV0aXJlcy4KaW50KCkgeyBjYXNlICIkMSIgaW4gJyd8KlshMC05XSopIGVj
aG8gIiR7MjotMH0iOzsgKikgX2k9JHsxIyIkezElJVshMF0qfSJ9OyBlY2hvICIke19pOi0wfSI7
OyBlc2FjOyB9CnRvaW50KCkgeyBldmFsICJjYXNlIFwiXCQkMVwiIGluICcnfCpbITAtOV0qKSAk
MT1cJHsyOi0wfTs7ICopICQxPVwkeyQxI1wiXCR7JDElJVshMF0qfVwifTsgJDE9XCR7JDE6LTB9
OzsgZXNhYyI7IH0gICAgIyB0b2ludCBWQVIgW2RlZmF1dF0gOiBzYW5zIHByb2Nlc3N1cwoKIyBF
Y3JpdHVyZSBhdG9taXF1ZSA6IGZpY2hpZXIgdGVtcG9yYWlyZSBkdSBtZW1lIGRvc3NpZXIsIHB1
aXMgcmVub21tYWdlLgpwdXQoKSB7IGVjaG8gIiQyIiA+ICIkMS50bXAuJCQiIDI+L2Rldi9udWxs
ICYmIG12IC1mICIkMS50bXAuJCQiICIkMSIgMj4vZGV2L251bGw7IH0KZ2V0KCkgeyBpZiBbIC1z
ICIkMSIgXTsgdGhlbiBoZWFkIC1uMSAiJDEiOyBlbHNlIGVjaG8gIiQyIjsgZmk7IH0KIyBSZXN1
bHRhdCBkZSBsYSBkZXJuaWVyZSBtaXNlIGEgam91ciA6IGVuIG1lbW9pcmUgdml2ZSAobHUgcGFy
IGxlcyBhbmNpZW5uZXMgdmVyc2lvbnMgZCdPcGVuUWlhcmEpIEVUIHN1ciBsYSBjYXJ0ZQojIChp
bCBzdXJ2aXQgYSB1biByZWRlbWFycmFnZSkuIEVjcml0IHNldWxlbWVudCBsb3JzIGQndW5lIG1p
c2UgYSBqb3VyIG91IGQndW4gcmV0b3VyIDogdXN1cmUgbmVnbGlnZWFibGUuCnJlc3VsdCgpIHsg
cHV0ICIkUlVOL2xhc3RfdXBkYXRlX3Jlc3VsdCIgIiQxIjsgcHV0ICIkU1QvbGFzdF91cGRhdGVf
cmVzdWx0IiAiJDEiOyB9Cmxhc3RfcmVzdWx0KCkgeyByZCBfbHIgIiRSVU4vbGFzdF91cGRhdGVf
cmVzdWx0IiAiIjsgWyAtbiAiJF9sciIgXSB8fCByZCBfbHIgIiRTVC9sYXN0X3VwZGF0ZV9yZXN1
bHQiIGF1Y3VuOyB9CnNoYV9vZigpIHsgc2hhMjU2c3VtICIkMSIgMj4vZGV2L251bGwgfCBjdXQg
LWQnICcgLWYxOyB9CiMgdjUgOiBsJ2FwcGxpY2F0aW9uIGxhbmNlZSBwYXIgbGUgbGFuY2V1ci4g
bGl2ZV9jaGlsZCBwb3NlIENIIGEgc29uIG51bWVybyBkZSBwcm9jZXNzdXMsIHNldWxlbWVudCBz
aSBjZSBudW1lcm8gdml0IEVUIHBvcnRlIGxlCiMgbm9tIGRlIGwnYXBwbGljYXRpb24gKG9wZW5x
aWFyYWQsIG91IG9wZW5xaWFyYWQub2xkIGVuIHJlcGxpIHVsdGltZSkgOiAkU1QvY2hpbGQgZXN0
IHN1ciBsYSBjYXJ0ZSwgaWwgc3Vydml0IGEgdW4gcmVkZW1hcnJhZ2UsCiMgZXQgbGUgbnVtZXJv
IHBldXQgYXZvaXIgZXRlIHJlcHJpcyBwYXIgdW4gYXV0cmUgcHJvZ3JhbW1lIChkcm9wYmVhciwg
aGxjYW1kLi4uKSBxdSd1biBhcnJldCBuZSBkb2l0IGphbWFpcyB0b3VjaGVyLgpBUFBfQ09NTT0k
e1FQX0FQUF9DT01NOi1vcGVucWlhcmFkfQpsaXZlX2NoaWxkKCkgewogIHJkIENIICIkU1QvY2hp
bGQiIDA7IHRvaW50IENIIDAKICBbICIkQ0giICE9IDAgXSAmJiBraWxsIC0wICIkQ0giIDI+L2Rl
di9udWxsIHx8IHsgQ0g9MDsgcmV0dXJuIDE7IH0KICBfYz07IHJlYWQgLXIgX2MgPCAvcHJvYy8k
Q0gvY29tbSAyPi9kZXYvbnVsbAogIGNhc2UgIiRfYyIgaW4gIiRBUFBfQ09NTSJ8IiRBUFBfQ09N
TSIuKikgcmV0dXJuIDA7OyBlc2FjCiAgQ0g9MDsgcmV0dXJuIDEKfQoKIyBEb3NzaWVyIGQndW4g
ZW1wbGFjZW1lbnQgOiBmYWN0b3J5IHN1ciAvZGF0YSAodG91am91cnMgcHJlc2VudCksIGdvb2Qg
ZXQgbmV3IHN1ciAvbWVkaWEuCnNkKCkgeyBjYXNlICIkMSIgaW4gZmFjdG9yeSkgZWNobyAiJFFQ
L3Nsb3RzL2ZhY3RvcnkiOzsgKikgZWNobyAiJEJVTEsvc2xvdHMvJDEiOzsgZXNhYzsgfQojIE9y
ZHJlIGRlIHJlcGxpIDogbmV3IC0+IGdvb2QgLT4gcHJldiAobGEgdmVyc2lvbiB2YWxpZGVlIGF2
YW50IGdvb2QpIC0+IGZhY3RvcnkgKG9yaWdpbmUsIHN1ciAvZGF0YSkKb3JkZXIoKSB7IGNhc2Ug
IiQxIiBpbiBuZXcpIGVjaG8gIm5ldyBnb29kIHByZXYgZmFjdG9yeSI7OyBnb29kKSBlY2hvICJn
b29kIHByZXYgZmFjdG9yeSI7OyBwcmV2KSBlY2hvICJwcmV2IGZhY3RvcnkiOzsgKikgZWNobyAi
ZmFjdG9yeSI7OyBlc2FjOyB9CgojIEFnZSBkJ3VuIGV2ZW5lbWVudCBkYXRlICJib290X2lkIHVw
dGltZSBob3Jsb2dlIiA6IGFnZV9vZiBCIFUgVyBwb3NlIEFHRSAoc2Vjb25kZXMpLCBtZXN1cmUg
c3VyIGwndXB0aW1lIHNpIG1lbWUgZGVtYXJyYWdlLAojIHN1ciBsJ2hvcmxvZ2UgbXVyYWxlIHNp
bm9uIGV0IHNldWxlbWVudCBzaSBlbGxlIGVzdCBwbGF1c2libGUgZGVzIGRldXggY290ZXMgKGFw
cmVzIDIwMjMtMTEsIGNyb2lzc2FudGUpIDsgQUdFPS0xIHNpIGluY29ubnUKIyAoYXV0cmUgZGVt
YXJyYWdlLCBob3Jsb2dlIGRlIDE5NzAgZCd1biBjb3RlKS4gVW4gVyBzZXVsIChhbmNpZW4gZm9y
bWF0LCBudW1lcmlxdWUpIHZhdXQgImF1dHJlIGRlbWFycmFnZSIuCmFnZV9vZigpIHsKICBfYWI9
JDE7IF9hdT0kMjsgX2F3PSQzOyBBR0U9LTEKICBib290X2lkOyB1cF9ub3cKICBpZiBbIC1uICIk
X2FiIiBdICYmIFsgIiRfYWIiID0gIiRCT09UIiBdOyB0aGVuIEFHRT0kKCggVVAgLSAkKGludCAi
JF9hdSIgMCkgKSk7IFsgIiRBR0UiIC1sdCAwIF0gJiYgQUdFPTA7IHJldHVybiAwOyBmaQogIF9h
bj0kKG5vdyk7IF9hdz0kKGludCAiJF9hdyIgMCkKICBpZiBbICIkX2FuIiAtZ3QgMTcwMDAwMDAw
MCBdICYmIFsgIiRfYXciIC1ndCAxNzAwMDAwMDAwIF0gJiYgWyAiJF9hbiIgLWdlICIkX2F3IiBd
OyB0aGVuIEFHRT0kKChfYW4gLSBfYXcpKTsgZmkKfQojIE1hcnF1YWdlIEJBRCA6ICJib290X2lk
IHVwdGltZSBob3Jsb2dlIG51bWVyb19kZV9kZW1hcnJhZ2UiLiBJbCBleHBpcmUgYXByZXMgUVBf
QkFEX1RUTCBzIChtZXN1cmUgc3VyIHVwdGltZSBzaSBtZW1lCiMgZGVtYXJyYWdlLCBzdXIgbCdo
b3Jsb2dlIHNpbm9uIGV0IHNldWxlbWVudCBzaSBlbGxlIGVzdCBwbGF1c2libGUpIG91LCBxdWFu
ZCBsJ2FnZSBlc3QgaW5jb25udSAocG9zZSBhIGwnaG9ybG9nZSBkZSAxOTcwLAojIHB1aXMgcmVk
ZW1hcnJhZ2UpLCBhcHJlcyBRUF9CQURfQk9PVFMgZGVtYXJyYWdlcyAodjYgOiBzYW5zIGNlbGEg
dW4gZW1wbGFjZW1lbnQgZWNhcnRlIGF2YW50IGxlIHJlZ2xhZ2UgZGUgbCdoZXVyZSBsJ2V0YWl0
CiMgcG91ciB0b3Vqb3VycykuIEVuIGNhcyBkZSBkb3V0ZSwgbCdlbXBsYWNlbWVudCByZXN0ZSBl
Y2FydGUuCkJBRF9UVEw9JHtRUF9CQURfVFRMOi0xODAwfQpCQURfQk9PVFM9JHtRUF9CQURfQk9P
VFM6LTJ9CnNsb3RfYmFkKCkgewogIF9mPSQoc2QgIiQxIikvQkFECiAgWyAtZSAiJF9mIiBdIHx8
IHJldHVybiAxCiAgWyAiJDEiID0gZmFjdG9yeSBdICYmIHJldHVybiAxICAgICAgICMgbGUgYmlu
YWlyZSBkJ29yaWdpbmUgbidlc3QgamFtYWlzIGVjYXJ0ZQogIF9iPTsgX3U9OyBfdz07IF9xPTsg
cmVhZCAtciBfYiBfdSBfdyBfcSA8ICIkX2YiIDI+L2Rldi9udWxsCiAgWyAteiAiJF91IiBdICYm
IFsgLXogIiRfdyIgXSAmJiB7IF93PSRfYjsgX2I9OyB9ICAgICAgICAjIGFuY2llbiBmb3JtYXQg
OiB1bmUgc2V1bGUgZGF0ZQogICMgdjYgOiB1biBtYXJxdWFnZSB2aWRlIG91IGlsbGlzaWJsZSAo
ZmljaGllciB0cm9ucXVlKSBuZSB2YXV0IHJpZW4gOiBpbCBlc3QgcmV0aXJlLiBVbmUgYm91Y2xl
IGQnYXJyZXRzIGxlIHJlcG9zZXJhaXQKICAjIGNvcnJlY3RlbWVudCBlbiBxdWVscXVlcyBzZWNv
bmRlcyA7IGxlIGdhcmRlciBhdXJhaXQgZWNhcnRlIGwnZW1wbGFjZW1lbnQgcG91ciB0b3Vqb3Vy
cy4KICBjYXNlICIke191Oi0wfSR7X3c6LTB9IiBpbiAqWyEwLTldKikgcm0gLWYgIiRfZiI7IGxv
ZyAibWFycXVhZ2UgQkFEIGRlICQxIGlsbGlzaWJsZSA6IHJldGlyZSI7IHJldHVybiAxOzsgZXNh
YwogIFsgLW4gIiRfdSRfdyIgXSB8fCB7IHJtIC1mICIkX2YiOyBsb2cgIm1hcnF1YWdlIEJBRCBk
ZSAkMSB2aWRlIDogcmV0aXJlIjsgcmV0dXJuIDE7IH0KICBhZ2Vfb2YgIiRfYiIgIiRfdSIgIiRf
dyIKICBpZiBbICIkQUdFIiAtbHQgMCBdOyB0aGVuCiAgICBfYWdlPTAKICAgIGNhc2UgIiRfcSIg
aW4gJyd8KlshMC05XSopIDs7ICopIGJvb3Rfc2VxX25vdzsgWyAkKChTRVEgLSAkKGludCAiJF9x
IiAwKSkpIC1nZSAiJEJBRF9CT09UUyIgXSAmJiBfYWdlPSRCQURfVFRMOzsgZXNhYwogIGVsc2Ug
X2FnZT0kQUdFOyBmaQogIFsgIiRfYWdlIiAtbHQgIiRCQURfVFRMIiBdICYmIHJldHVybiAwCiAg
cm0gLWYgIiRfZiI7IHJldHVybiAxCn0KIyBFbXBsYWNlbWVudCB1dGlsaXNhYmxlIDogYmluYWly
ZSBub24gdmlkZSwgbm9uIEJBRCwgZW1wcmVpbnRlIGNvbmZvcm1lIChleGlnZWUgcG91ciBnb29k
IGV0IG5ldykuIFBvc2UgJFZTSEEuCnNsb3RfdmFsaWQoKSB7CiAgX2Q9JChzZCAiJDEiKTsgVlNI
QT0KICBbIC1zICIkX2Qvb3BlbnFpYXJhZCIgXSB8fCByZXR1cm4gMQogIHNsb3RfYmFkICIkMSIg
JiYgcmV0dXJuIDEKICBpZiBbIC1zICIkX2Qvb3BlbnFpYXJhZC5zaGEyNTYiIF07IHRoZW4KICAg
IF93YW50PTsgcmVhZCAtciBfd2FudCBfeCA8ICIkX2Qvb3BlbnFpYXJhZC5zaGEyNTYiCiAgICBW
U0hBPSQoc2hhX29mICIkX2Qvb3BlbnFpYXJhZCIpCiAgICBbICIkX3dhbnQiID0gIiRWU0hBIiBd
IHx8IHJldHVybiAxCiAgZWxzZQogICAgWyAiJDEiID0gZmFjdG9yeSBdIHx8IHJldHVybiAxCiAg
ZmkKICByZXR1cm4gMAp9Cm1hcmtfYmFkKCkgeyBbICIkMSIgPSBmYWN0b3J5IF0gJiYgcmV0dXJu
IDA7IGJvb3Rfc2VxX25vdzsgdXBfbm93OyBwdXQgIiQoc2QgIiQxIikvQkFEIiAiJEJPT1QgJFVQ
ICQobm93KSAkU0VRIjsgbG9nICJlbXBsYWNlbWVudCAkMSBtYXJxdWUgQkFEIjsgfQpNSU5TWj0k
e1FQX01JTl9TSVpFOi0xMDAwMDAwfQpNQVhTWj0ke1FQX01BWF9TSVpFOi0yNDAwMDAwMH0gICAj
IHVuIGJpbmFpcmUgbm9uIGNvbXByZXNzZSAoc2FucyBVUFgpIGZhaXQgfjExIE1vClNBRkVUWV9L
Qj0ke1FQX1NBRkVUWV9LQjotNDA5Nn0KCmRpZSgpIHsgZWNobyAiRVJSRVVSOiAkKiIgPiYyOyBs
b2cgIkVSUkVVUjogJCoiOyBleGl0IDE7IH0KCmZyZWVfa2IoKSB7ICMgcGxhY2UgbGlicmUgZW4g
S2lvIDsgdmlkZSBzaSBkZiBuZSBzYWl0IHBhcyByZXBvbmRyZSAobGUgY29udHJvbGUgZXN0IGFs
b3JzIHNhdXTDqSwgY3AgZWNob3VlcmEgcHJvcHJlbWVudCkKICBbIC1uICIkUVBfRkFLRV9GUkVF
IiBdICYmIHsgZWNobyAiJFFQX0ZBS0VfRlJFRSI7IHJldHVybjsgfQogIGRmIC1rICIkMSIgMj4v
ZGV2L251bGwgfCBhd2sgJ05SPT0yICYmICQ0IH4gL15bMC05XSskLyB7cHJpbnQgJDR9Jwp9Cgoj
IExlIGZpY2hpZXIgZXN0LWlsIHVuIGV4ZWN1dGFibGUgRUxGIDMyIGJpdHMgQVJNIGRlIHRhaWxs
ZSBwbGF1c2libGUgPwpjaGVja19lbGYoKSB7ICMgY2hlY2tfZWxmIGZpY2hpZXIKICBmPSQxCiAg
WyAtcyAiJGYiIF0gfHwgZGllICJmaWNoaWVyIHZpZGUgb3UgYWJzZW50IDogJGYiCiAgc3o9JCh3
YyAtYyA8ICIkZiIpOyBbICIkc3oiIC1nZSAiJE1JTlNaIiBdICYmIFsgIiRzeiIgLWxlICIkTUFY
U1oiIF0gfHwgZGllICJ0YWlsbGUgJHN6IGhvcnMgZGUgWyRNSU5TWiwkTUFYU1pdIgogIGhkcj0k
KG9kIC1BbiAtdHgxIC1OMjAgIiRmIiB8IHRyIC1kICcgXG4nKQogIGNhc2UgIiRoZHIiIGluCiAg
ICA3ZjQ1NGM0NiopIDs7CiAgICAqKSBkaWUgImNlIG4nZXN0IHBhcyB1biBleGVjdXRhYmxlIEVM
RiIgOzsKICBlc2FjCiAgIyBvY3RldCA1ID0gY2xhc3NlICgwMSA9IDMyIGJpdHMpLCBvY3RldCAx
OSAob2Zmc2V0IDE4KSA9IG1hY2hpbmUgKDI4ID0gQVJNKQogIFsgIiQoZWNobyAiJGhkciIgfCBj
dXQgLWM5LTEwKSIgPSAwMSBdIHx8IGRpZSAiRUxGIG5vbiAzMiBiaXRzIgogIFsgIiQoZWNobyAi
JGhkciIgfCBjdXQgLWMzNy0zOCkiID0gMjggXSB8fCBkaWUgIkVMRiBub24gQVJNIgp9CgojIENv
cGllIGF0b21pcXVlIGV0IHZlcmlmaWVlIDogZmljaGllci5wYXJ0IC0+IHN5bmMgLT4gZW1wcmVp
bnRlIC0+IHJlbm9tbWFnZS4KIyBRUF9MSU5LPTEgOiBsaWVuIHBoeXNpcXVlIGF1IGxpZXUgZCd1
bmUgY29waWUgcXVhbmQgc291cmNlIGV0IGRlc3RpbmF0aW9uIHNvbnQgc3VyIGxhIG1lbWUgcGFy
dGl0aW9uCiMgKGJpbmFpcmUgZCdvcmlnaW5lIHN1ciAvZGF0YSA6IGF1Y3VuZSBwbGFjZSBjb25z
b21tZWUpLiBMYSBwbGFjZSBkZW1hbmRlZSA9IHRhaWxsZSBkdSBmaWNoaWVyICsgcmVzZXJ2ZQoj
IChsJ2FuY2llbiBmaWNoaWVyIGRlIGwnZW1wbGFjZW1lbnQgbidlc3QgbGliZXJlIHF1J2F1IHJl
bm9tbWFnZSBmaW5hbCkuCmluc3RhbGxfZmlsZSgpIHsgIyBpbnN0YWxsX2ZpbGUgc291cmNlIGRv
c3NpZXJfZGVzdCBbc2hhX2F0dGVuZHVdCiAgc3JjPSQxOyBkc3Q9JDI7IHdhbnQ9JDMKICBta2Rp
ciAtcCAiJGRzdCIgfHwgZGllICJkb3NzaWVyICRkc3QgaW1wb3NzaWJsZSIKICBzej0kKHdjIC1j
IDwgIiRzcmMiKQogIHNyY3NoYT0kKHNoYV9vZiAiJHNyYyIpCiAgWyAteiAiJHdhbnQiIF0gfHwg
WyAiJHdhbnQiID0gIiRzcmNzaGEiIF0gfHwgZGllICJlbXByZWludGUgZHUgZmljaGllciBzb3Vy
Y2UgZGlmZmVyZW50ZSBkZSBjZWxsZSBhdHRlbmR1ZSIKICBybSAtZiAiJGRzdC9vcGVucWlhcmFk
LnBhcnQiCiAgbGlua2VkPTAKICBbIC1uICIkUVBfTElOSyIgXSAmJiBsbiAiJHNyYyIgIiRkc3Qv
b3BlbnFpYXJhZC5wYXJ0IiAyPi9kZXYvbnVsbCAmJiBsaW5rZWQ9MQogIGlmIFsgIiRsaW5rZWQi
ID0gMCBdOyB0aGVuCiAgICBuZWVkPSQoKCBzeiAvIDEwMjQgKyBTQUZFVFlfS0IgKSkKICAgIGhh
dmU9JChmcmVlX2tiICIkZHN0IikKICAgIGlmIFsgLW4gIiRoYXZlIiBdOyB0aGVuCiAgICAgIFsg
IiRoYXZlIiAtZ2UgIiRuZWVkIiBdIHx8IGRpZSAicGxhY2UgaW5zdWZmaXNhbnRlIGRhbnMgJGRz
dCA6ICR7aGF2ZX0gS2lvIGxpYnJlcywgJHtuZWVkfSBLaW8gbmVjZXNzYWlyZXMiCiAgICBmaQog
ICAgY3AgIiRzcmMiICIkZHN0L29wZW5xaWFyYWQucGFydCIgfHwgeyBybSAtZiAiJGRzdC9vcGVu
cWlhcmFkLnBhcnQiOyBkaWUgImNvcGllIGltcG9zc2libGUgKGRpc3F1ZSBwbGVpbiA/KSI7IH0K
ICBmaQogIHN5bmMKICBbICIkKHNoYV9vZiAiJGRzdC9vcGVucWlhcmFkLnBhcnQiKSIgPSAiJHNy
Y3NoYSIgXSB8fCB7IHJtIC1mICIkZHN0L29wZW5xaWFyYWQucGFydCI7IGRpZSAibGEgY29waWUg
bidhIHBhcyBsYSBtZW1lIGVtcHJlaW50ZSBxdWUgbGEgc291cmNlIjsgfQogIGNobW9kIDc1NSAi
JGRzdC9vcGVucWlhcmFkLnBhcnQiCiAgIyBMJ2VtcGxhY2VtZW50IGRldmllbnQgaW51dGlsaXNh
YmxlIGxlIHRlbXBzIGR1IHJlbXBsYWNlbWVudCAocGFzIGQnZW1wcmVpbnRlKSwgcHVpcyByZWRl
dmllbnQgdmFsaWRlIGQndW4gY291cC4KICBybSAtZiAiJGRzdC9vcGVucWlhcmFkLnNoYTI1NiIg
IiRkc3QvQkFEIiAiJGRzdC9IRUFMVEhfU0VFTiIKICBtdiAtZiAiJGRzdC9vcGVucWlhcmFkLnBh
cnQiICIkZHN0L29wZW5xaWFyYWQiIHx8IGRpZSAicmVub21tYWdlIGltcG9zc2libGUiCiAgcHV0
ICIkZHN0L29wZW5xaWFyYWQuc2hhMjU2IiAiJHNyY3NoYSAgb3BlbnFpYXJhZCIKICBzeW5jCiAg
WyAiJChzaGFfb2YgIiRkc3Qvb3BlbnFpYXJhZCIpIiA9ICIkc3Jjc2hhIiBdIHx8IGRpZSAiY29u
dHJvbGUgZmluYWwgZGUgJGRzdCBlbiBlY2hlYyIKICBlY2hvICIkc3Jjc2hhIgp9CgojIHY2IDog
bGEgY29waWUgZGUgc2Vjb3VycyAkT0xEIChsdWUgcGFyIGxlIGxhbmNldXIgcXVhbmQgYXVjdW4g
ZW1wbGFjZW1lbnQgbidlc3QgdXRpbGlzYWJsZSwgZXQgcGFyIHBvc3RfYm9vdC5zaCBxdWFuZAoj
IC9kYXRhL29wZW5xaWFyYWQgYSBkaXNwYXJ1KSBzdWl0IGxhIHZlcnNpb24gZGUgcmVmZXJlbmNl
IDogc2FucyBjZWxhIGVsbGUgcmVzdGUgbGUgYmluYWlyZSBkdSAyNC8xMCAoYW5jaWVuLCBjb21w
cmVzc2UgVVBYKS4KIyBDb3BpZSB2ZXJpZmllZSwgZW1wcmVpbnRlIGEgY290ZSA7IHVuIGVjaGVj
IChwbGFjZSwgY2FydGUpIG4nZW1wZWNoZSBwYXMgbCdvcGVyYXRpb24gcHJpbmNpcGFsZS4KcmVm
cmVzaF9vbGQoKSB7ICMgcmVmcmVzaF9vbGQgc291cmNlCiAgWyAtbiAiJFFQX05PX09MRCIgXSAm
JiByZXR1cm4gMAogIF9vcz0kKHNoYV9vZiAiJDEiKTsgWyAtbiAiJF9vcyIgXSB8fCByZXR1cm4g
MAogIFsgIiQoc2hhX29mICIkT0xEIikiID0gIiRfb3MiIF0gJiYgcmV0dXJuIDAKICBybSAtZiAi
JE9MRC5wYXJ0IgogICMgdjkgOiBsJ2FuY2llbm5lIGVtcHJlaW50ZSBlc3QgcmV0aXJlZSBhdmFu
dCBsZSByZW5vbW1hZ2UgOyB1bmUgY291cHVyZSBlbnRyZSBsZXMgZGV1eCBsYWlzc2UgdW5lIGNv
cGllIHNhbnMgZW1wcmVpbnRlCiAgIyAoYWNjZXB0ZWUgcGFyIGxlIGxhbmNldXIsIGNvbXBvcnRl
bWVudCB2NSkgZXQgbm9uIHVuZSBjb3BpZSByZWZ1c2VlIHBvdXIgZW1wcmVpbnRlIGRpZmZlcmVu
dGUuCiAgaWYgY3AgIiQxIiAiJE9MRC5wYXJ0IiAyPi9kZXYvbnVsbCAmJiBzeW5jICYmIFsgIiQo
c2hhX29mICIkT0xELnBhcnQiKSIgPSAiJF9vcyIgXSAmJiBjaG1vZCA3NTUgIiRPTEQucGFydCIg
JiYgcm0gLWYgIiRPTEQuc2hhMjU2IiAmJiBtdiAtZiAiJE9MRC5wYXJ0IiAiJE9MRCI7IHRoZW4K
ICAgIHB1dCAiJE9MRC5zaGEyNTYiICIkX29zICBvcGVucWlhcmFkLm9sZCI7IHN5bmM7IGxvZyAi
Y29waWUgZGUgc2Vjb3VycyAkT0xEIG1pc2UgYSBqb3VyICgkKGVjaG8gIiRfb3MiIHwgY3V0IC1j
MS0xMikpIgogIGVsc2UKICAgIHJtIC1mICIkT0xELnBhcnQiOyBsb2cgImNvcGllIGRlIHNlY291
cnMgJE9MRCBub24gbWlzZSBhIGpvdXIgKHBsYWNlIG91IGNhcnRlKSA6IGwnYW5jaWVubmUgcmVz
dGUgZW4gc2VydmljZSIKICBmaQogIHJldHVybiAwCn0KCmNtZD0kMTsgc2hpZnQKY2FzZSAiJGNt
ZCIgaW4KICBzdGFnZSkKICAgIGY9JDE7IHdhbnQ9JDIKICAgIFsgLW4gIiRmIiBdIHx8IGRpZSAi
c3RhZ2UgOiBmaWNoaWVyIG1hbnF1YW50IgogICAgY2hlY2tfZWxmICIkZiIKICAgICMgdjYgOiBw
ZW5kYW50IHVuIGVzc2FpIGRvbnQgbCdhcHBsaWNhdGlvbiB0b3VybmUsIHJlbXBsYWNlciBuZXcg
ZmVyYWl0IHZhbGlkZXIgKHByb21vdGUpIHVuIGJpbmFpcmUgcXVpIG4nYSBqYW1haXMgdG91cm5l
CiAgICBpZiBbIC1lICIkU1QvdHJpYWwiIF0gJiYgWyAiJChnZXQgIiRTVC9ydW5uaW5nX3Nsb3Qi
IG5vbmUpIiA9IG5ldyBdICYmIGxpdmVfY2hpbGQgJiYgWyAteiAiJFFQX0ZPUkNFIiBdOyB0aGVu
CiAgICAgIGRpZSAidW4gZXNzYWkgZXN0IGVuIGNvdXJzIChuZXcgdG91cm5lLCBwaWQgJENIKSA6
IHJvbGxiYWNrIG91IHByb21vdGUgZCdhYm9yZCIKICAgIGZpCiAgICBzaGE9JChpbnN0YWxsX2Zp
bGUgIiRmIiAiJChzZCBuZXcpIiAiJHdhbnQiKSB8fCBleGl0IDEKICAgIHB1dCAiJFNUL25ld19z
dGFydHMiIDA7IHB1dCAiJFNUL2ZhaWxzIiAwOyBwdXQgIiRTVC90cmlhbCIgIiQobm93KSAkc2hh
IgogICAgcHV0ICIkU1QvYWN0aXZlIiBuZXcKICAgIHJlc3VsdCAiZXNzYWkgZW4gY291cnMgOiAk
KGVjaG8gIiRzaGEiIHwgY3V0IC1jMS0xMikiCiAgICBsb2cgIm5vdXZlYXUgYmluYWlyZSBkZXBv
c2UgZGFucyBuZXcgKCQoZWNobyAiJHNoYSIgfCBjdXQgLWMxLTEyKSksIGVzc2FpIGF1IHByb2No
YWluIGRlbWFycmFnZSIKICAgIHN5bmMgICAgIyB2NC4xIDogbCdldGF0IGRlIGwnZXNzYWkgKGFj
dGl2ZSwgdHJpYWwpIGRvaXQgZXRyZSBzdXIgbGEgY2FydGUgYXZhbnQgbGEgcmVsYW5jZQogICAg
ZWNobyAiT0sgbmV3PSRzaGEiCiAgICA7OwogIHByb21vdGUpCiAgICBbIC1zICIkKHNkIG5ldykv
b3BlbnFpYXJhZCIgXSB8fCBkaWUgImVtcGxhY2VtZW50IG5ldyB2aWRlIgogICAgc2xvdF92YWxp
ZCBuZXcgfHwgZGllICJlbXBsYWNlbWVudCBuZXcgaW52YWxpZGUiCiAgICBydW49JChnZXQgIiRT
VC9ydW5uaW5nX3Nsb3QiIG5vbmUpCiAgICBpZiB7IFsgIiRydW4iICE9IG5ldyBdIHx8ICEgbGl2
ZV9jaGlsZDsgfSAmJiBbICIkMSIgIT0gLS1mb3JjZSBdOyB0aGVuIGRpZSAibmV3IG5lIHRvdXJu
ZSBwYXMgKGRlcm5pZXIgbGFuY2UgOiAkcnVuKSI7IGZpCiAgICAjIHY2IDogbGUgYmluYWlyZSB2
YWxpZGUgZG9pdCBldHJlIGNlbHVpIHF1aSBhIGZhaXQgbCdlc3NhaSA6IG1lbWUgZW1wcmVpbnRl
IHF1ZSBjZWxsZSBub3RlZSBhdSBkZXBvdCAobWFycXVldXIgImRhdGUgc2hhIiksCiAgICAjIGV0
LCBzaSBuZXcgdG91cm5lLCB1biBleGVjdXRhYmxlIHRvdWpvdXJzIHByZXNlbnQgc3VyIGxhIGNh
cnRlIChzaW5vbiAvcHJvYy9waWQvZXhlIHNlIHRlcm1pbmUgcGFyIMKrIChkZWxldGVkKSDCuykK
ICAgIF90dz07IF90cz07IFsgLXMgIiRTVC90cmlhbCIgXSAmJiByZWFkIC1yIF90dyBfdHMgPCAi
JFNUL3RyaWFsIgogICAgWyAteiAiJF90cyIgXSB8fCBbICIkX3RzIiA9ICIkKHNoYV9vZiAiJChz
ZCBuZXcpL29wZW5xaWFyYWQiKSIgXSB8fCBkaWUgIm5ldyBuJ2VzdCBwbHVzIGxlIGJpbmFpcmUg
ZGVwb3NlIHBvdXIgbCdlc3NhaSAoJChlY2hvICIkX3RzIiB8IGN1dCAtYzEtMTIpIGF0dGVuZHUp
IDogcGFzIGRlIHZhbGlkYXRpb24iCiAgICBpZiBbICIkcnVuIiA9IG5ldyBdICYmIGxpdmVfY2hp
bGQ7IHRoZW4gY2FzZSAiJChyZWFkbGluayAvcHJvYy8kQ0gvZXhlIDI+L2Rldi9udWxsKSIgaW4g
KiIgKGRlbGV0ZWQpIikgZGllICJsZSBiaW5haXJlIHF1aSB0b3VybmUgbidlc3QgcGx1cyBjZWx1
aSBkZSBuZXcgKHJlbXBsYWNlIHNvdXMgbCdhcHBsaWNhdGlvbikgOiBwYXMgZGUgdmFsaWRhdGlv
biI7OyBlc2FjOyBmaQogICAgIyBsYSB2ZXJzaW9uIHZhbGlkZWUganVzcXUnaWNpIGVzdCBnYXJk
ZWUgZW4gcHJldiA6IHJldG91ciBwb3NzaWJsZSBtZW1lIGFwcmVzIHZhbGlkYXRpb24KICAgIGlm
IHNsb3RfdmFsaWQgZ29vZCAmJiBbICIkKHNoYV9vZiAiJChzZCBnb29kKS9vcGVucWlhcmFkIiki
ICE9ICIkKHNoYV9vZiAiJChzZCBuZXcpL29wZW5xaWFyYWQiKSIgXTsgdGhlbgogICAgICBpbnN0
YWxsX2ZpbGUgIiQoc2QgZ29vZCkvb3BlbnFpYXJhZCIgIiQoc2QgcHJldikiID4vZGV2L251bGwg
fHwgbG9nICJjb3BpZSBkZSBnb29kIHZlcnMgcHJldiBpbXBvc3NpYmxlIChvbiBjb250aW51ZSki
CiAgICBmaQogICAgc2hhPSQoaW5zdGFsbF9maWxlICIkKHNkIG5ldykvb3BlbnFpYXJhZCIgIiQo
c2QgZ29vZCkiKSB8fCBleGl0IDEKICAgIHB1dCAiJFNUL2FjdGl2ZSIgZ29vZDsgcm0gLWYgIiRT
VC90cmlhbCI7IHB1dCAiJFNUL25ld19zdGFydHMiIDA7IHB1dCAiJFNUL2ZhaWxzIiAwCiAgICBy
ZXN1bHQgIm9rOiAkKGVjaG8gIiRzaGEiIHwgY3V0IC1jMS0xMikgdmFsaWRlIgogICAgbG9nICJl
c3NhaSByZXVzc2kgOiBuZXcgcHJvbXUgZW4gZ29vZCAoJChlY2hvICIkc2hhIiB8IGN1dCAtYzEt
MTIpKSIKICAgIHN5bmMKICAgIHJlZnJlc2hfb2xkICIkKHNkIGdvb2QpL29wZW5xaWFyYWQiCiAg
ICBlY2hvICJPSyBnb29kPSRzaGEiCiAgICA7OwogIHJvbGxiYWNrKQogICAgIyBzYW5zIGVzc2Fp
IGVuIGNvdXJzLCByaWVuIGEgYW5udWxlciAodW4gYXBwdWkgdGFyZGlmIGFwcmVzIHVuZSB2YWxp
ZGF0aW9uIG5lIGRvaXQgcGFzIGVjYXJ0ZXIgbGEgYm9ubmUgdmVyc2lvbikKICAgIGlmIFsgISAt
ZSAiJFNUL3RyaWFsIiBdICYmIFsgLXogIiRRUF9GT1JDRSIgXTsgdGhlbgogICAgICByZXN1bHQg
InJpZW4gYSBhbm51bGVyIDogYXVjdW4gZXNzYWkgZW4gY291cnMiOyBsb2cgInJldG91ciBhcnJp
ZXJlIGRlbWFuZGUgc2FucyBlc3NhaSBlbiBjb3VycyA6IGlnbm9yZSI7IGVjaG8gIk9LIChhdWN1
biBlc3NhaSkiOyBleGl0IDAKICAgIGZpCiAgICBtYXJrX2JhZCBuZXcKICAgIHB1dCAiJFNUL2Fj
dGl2ZSIgZ29vZDsgcm0gLWYgIiRTVC90cmlhbCI7IHB1dCAiJFNUL25ld19zdGFydHMiIDA7IHB1
dCAiJFNUL2ZhaWxzIiAwCiAgICByZXN1bHQgImFubnVsZTogcmV0b3VyIGEgZ29vZCR7MTorICgk
MSl9IgogICAgbG9nICJyZXRvdXIgYXJyaWVyZSA6IG5ldyBlY2FydGUsIHJldG91ciBhIGdvb2Qk
ezE6KyAoJDEpfSIKICAgIHN5bmMKICAgIGlmIFsgIiQoZ2V0ICIkU1QvcnVubmluZ19zbG90IiBu
b25lKSIgPSBuZXcgXTsgdGhlbgogICAgICBpZiBsaXZlX2NoaWxkOyB0aGVuCiAgICAgICAgdHJ1
ZSAyPi9kZXYvbnVsbCA+ICIkU1QvZXhwZWN0ZWRfc3RvcCI7IGtpbGwgIiRDSCIgMj4vZGV2L251
bGwgJiYgZWNobyAiYmluYWlyZSBuZXcgYXJyZXRlLCBsZSBsYW5jZXVyIHJlbGFuY2UgZ29vZCIK
ICAgICAgZmkKICAgIGZpCiAgICBlY2hvICJPSyIKICAgIDs7CiAgdXNlLXByZXYpCiAgICBzbG90
X3ZhbGlkIHByZXYgfHwgZGllICJlbXBsYWNlbWVudCBwcmV2IGFic2VudCBvdSBpbnZhbGlkZSIK
ICAgICMgdjYgOiBkZWphIHN1ciBwcmV2IGV0IHByZXYgdG91cm5lIDogcmllbiBhIGZhaXJlICh1
biBvcmRyZSByZXBldGUgbmUgcmVsYW5jZSBwYXMgbCdhcHBsaWNhdGlvbikKICAgIGlmIFsgIiQo
Z2V0ICIkU1QvYWN0aXZlIiBnb29kKSIgPSBwcmV2IF0gJiYgWyAiJChnZXQgIiRTVC9ydW5uaW5n
X3Nsb3QiIG5vbmUpIiA9IHByZXYgXSAmJiBsaXZlX2NoaWxkOyB0aGVuCiAgICAgIGxvZyAicmV0
b3VyIGEgcHJldiBkZW1hbmRlIDogZGVqYSBlbiBjb3VycyAocGlkICRDSCksIHJpZW4gZmFpdCI7
IGVjaG8gIk9LIGFjdGl2ZT1wcmV2IChkZWphKSI7IGV4aXQgMAogICAgZmkKICAgIHB1dCAiJFNU
L2FjdGl2ZSIgcHJldjsgcm0gLWYgIiRTVC90cmlhbCIKICAgIHJlc3VsdCAicmV0b3VyIGEgbGEg
dmVyc2lvbiBwcmVjZWRlbnRlIChwcmV2KSIKICAgIGxvZyAicmV0b3VyIGRlbWFuZGUgYSBsYSB2
ZXJzaW9uIHByZWNlZGVudGUgKHByZXYpIgogICAgc3luYwogICAgaWYgbGl2ZV9jaGlsZDsgdGhl
biB0cnVlIDI+L2Rldi9udWxsID4gIiRTVC9leHBlY3RlZF9zdG9wIjsga2lsbCAiJENIIiAyPi9k
ZXYvbnVsbDsgZmkKICAgIGVjaG8gIk9LIGFjdGl2ZT1wcmV2IgogICAgOzsKICBzZWVkLWZhY3Rv
cnl8c2VlZC1nb29kKQogICAgZj0kMTsgWyAtbiAiJGYiIF0gfHwgZGllICIkY21kIDogZmljaGll
ciBtYW5xdWFudCIKICAgIGNoZWNrX2VsZiAiJGYiCiAgICBzbG90PSR7Y21kI3NlZWQtfQogICAg
aWYgWyAiJHNsb3QiID0gZmFjdG9yeSBdOyB0aGVuIHNoYT0kKFFQX0xJTks9MSBpbnN0YWxsX2Zp
bGUgIiRmIiAiJChzZCAkc2xvdCkiICIkMiIpIHx8IGV4aXQgMQogICAgZWxzZSBzaGE9JChpbnN0
YWxsX2ZpbGUgIiRmIiAiJChzZCAkc2xvdCkiICIkMiIpIHx8IGV4aXQgMTsgZmkKICAgIFsgIiRz
bG90IiA9IGdvb2QgXSAmJiBbICEgLXMgIiRTVC9hY3RpdmUiIF0gJiYgcHV0ICIkU1QvYWN0aXZl
IiBnb29kCiAgICBsb2cgIiRzbG90IGluc3RhbGxlICgkKGVjaG8gIiRzaGEiIHwgY3V0IC1jMS0x
MikpIgogICAgWyAiJHNsb3QiID0gZ29vZCBdICYmIHJlZnJlc2hfb2xkICIkKHNkIGdvb2QpL29w
ZW5xaWFyYWQiCiAgICBlY2hvICJPSyAkc2xvdD0kc2hhIgogICAgOzsKICBzdGF0dXMpCiAgICB7
CiAgICAgIGVjaG8gImFjdGl2ZT0kKGdldCAiJFNUL2FjdGl2ZSIgZ29vZCkiCiAgICAgIHI9JChn
ZXQgIiRTVC9ydW5uaW5nX3Nsb3QiIG5vbmUpOyBsaXZlX2NoaWxkIHx8IHI9ImF1Y3VuIChkZXJu
aWVyIDogJHIpIgogICAgICBlY2hvICJydW5uaW5nPSRyIgogICAgICBlY2hvICJ0cmlhbD0kKFsg
LWUgIiRTVC90cmlhbCIgXSAmJiBlY2hvIDEgfHwgZWNobyAwKSIKICAgICAgZWNobyAiZmFpbHM9
JChnZXQgIiRTVC9mYWlscyIgMCkiCiAgICAgIGVjaG8gIm5ld19zdGFydHM9JChnZXQgIiRTVC9u
ZXdfc3RhcnRzIiAwKSIKICAgICAgZm9yIHMgaW4gZmFjdG9yeSBwcmV2IGdvb2QgbmV3OyBkbwog
ICAgICAgIGQ9JChzZCAkcykKICAgICAgICB2PW5vbmU7IFsgLXMgIiRkL29wZW5xaWFyYWQiIF0g
JiYgdj0kKHNoYV9vZiAiJGQvb3BlbnFpYXJhZCIgfCBjdXQgLWMxLTEyKQogICAgICAgIGI9MDsg
c2xvdF9iYWQgJHMgJiYgYj0xCiAgICAgICAgZWNobyAic2xvdF8kcz0kdiBiYWQ9JGIgdmFsaWQ9
JChzbG90X3ZhbGlkICRzICYmIGVjaG8gMSB8fCBlY2hvIDApIgogICAgICBkb25lCiAgICAgIGxh
c3RfcmVzdWx0OyBlY2hvICJsYXN0X3Jlc3VsdD0kX2xyIgogICAgICBlY2hvICJmcmVlX2RhdGFf
a2I9JChmcmVlX2tiICIkUVAiKSIKICAgICAgZWNobyAiZnJlZV9idWxrX2tiPSQoZnJlZV9rYiAi
JEJVTEsiKSIKICAgIH0gfCB0ZWUgIiRSVU4vc3RhdHVzLXVwZGF0ZSIKICAgIDs7CiAgKikgZWNo
byAidXNhZ2U6IHFwLXVwZGF0ZSBzdGFnZXxwcm9tb3RlfHJvbGxiYWNrfHVzZS1wcmV2fHNlZWQt
ZmFjdG9yeXxzZWVkLWdvb2R8c3RhdHVzIiA+JjI7IGV4aXQgMiA7Owplc2FjCg==
