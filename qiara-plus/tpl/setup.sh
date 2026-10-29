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
