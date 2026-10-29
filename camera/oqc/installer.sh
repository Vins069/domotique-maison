#!/bin/sh
# installer.sh : termine sur la camera l'installation d'OpenQIARA Claude V15 et de QIARA Plus v10.
# Lance par le bloc « openqiara-claude-v15 » de /data/post_boot.sh, a la fin de chaque demarrage, tant que
# /media/oqc/A-INSTALLER ou /media/oqc/A-VERIFIER existe. Le meme programme sert aux deux chemins :
#   - carte SD preparee hors ligne (preparer-carte-sd.sh) : /data/openqiarad est deja OpenQIARA Claude V15 ;
#   - mise a niveau par SSH d'une camera sous OpenQiara (mettre-a-niveau.sh) : le binaire en service est remplace.
# Etapes (chacune journalisee dans /media/oqc/installation.log, l'avancement dans /media/oqc/etat) :
#   1. attente d'un demarrage complet (OpenQiara en marche depuis au moins 60 s) ;
#   2. OpenQIARA Claude V15 en service (empreinte verifiee), reglages par defaut fusionnes par OpenQiara au demarrage ;
#      /data ne fait que 20 Mio : la version compacte (UPX) y est posee, elle devient le secours « factory » ;
#   3. QIARA Plus v10 (qp-setup.sh install --yes : controles, essai a blanc, retour arriere automatique si echec), puis
#      la version complete mise en essai dans l'emplacement new (sur /media) et validee par le surveillant ;
#   4. services du cloud Qiara neutralises a la source (si demande), copie de securite et retour possibles ;
#   5. redemarrage (pour que boot.sh relance hlcamd avec le codec, le debit et l'image cle choisis) ;
#   6. apres ce redemarrage : verification et rapport (/media/oqc/rapport.txt).
# Usage manuel : sh /media/oqc/installer.sh [etat|verifier]
OQC=${OQC:-/media/oqc}
DATA=${OQC_DATA:-/data}
LOG=$OQC/installation.log
ETAT=$OQC/etat
CONF=$OQC/installation.conf
APP=$DATA/openqiarad
V15=$OQC/openqiarad-claude-v15            # binaire complet : celui qui tourne, depuis /media (emplacement good de QIARA Plus)
V15C=$OQC/openqiarad-claude-v15-compact   # meme version compressee (UPX, 4 Mio) : celle de /data (emplacement factory, secours)
LOCK=/tmp/oqc-installer.lock
REBOOT_CMD=${OQC_REBOOT:-reboot}
WAIT_MAX=${OQC_WAIT_MAX:-900}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; echo "$*"; }
etat() { echo "$*" > "$ETAT.tmp" && mv -f "$ETAT.tmp" "$ETAT"; log "== etat : $*"; }
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }
app_pid() { for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = openqiarad ] && { echo "${p#/proc/}"; return 0; }; done; return 1; }
is_launcher() { [ "$(head -c 2 "$APP" 2>/dev/null)" = '#!' ]; }
uptime_s() { read -r u _r < /proc/uptime; echo "${u%%.*}"; }
conf() { # conf NOM defaut : valeur de installation.conf (lignes NOM=valeur, lues, jamais executees)
  v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '\r"')
  echo "${v:-$2}"
}
pid_age() { # secondes depuis le lancement du processus $1 (champ 22 de /proc/pid/stat, en tops d'horloge)
  t=$(awk '{print $22}' "/proc/$1/stat" 2>/dev/null); [ -n "$t" ] || { echo 0; return; }
  echo $(( $(uptime_s) - t / 100 ))
}
wait_app() { # wait_app secondes_de_marche delai_max : OpenQiara en marche depuis au moins N s
  i=0
  while [ "$i" -lt "$2" ]; do
    p=$(app_pid) && [ "$(pid_age "$p")" -ge "$1" ] && return 0
    sleep 5; i=$((i + 5))
  done
  return 1
}
port80() { netstat -tln 2>/dev/null | grep -q ':80 '; }
qp_a_jour() { # les outils QIARA Plus installes sont ceux de ce paquet (empreintes integrees a qp-setup.sh)
  for t in qp-guard qp-update; do
    w=$(sed -n "s/^@@FILE $t //p" "$OQC/qp-setup.sh" | head -n 1)
    [ -n "$w" ] && [ "$(sha_of "$DATA/qp/$t")" = "$w" ] || return 1
  done
  w=$(sed -n "s/^@@FILE qp-launch //p" "$OQC/qp-setup.sh" | head -n 1); [ "$(sha_of "$APP")" = "$w" ]
}

# ---------------------------------------------------------------- reprise apres une coupure de courant
# Si le courant a coupe pendant le remplacement du binaire (etape 2), /data/openqiarad peut manquer : la camera ne serait
# plus une passerelle radio. Il est remis avant toute attente : V15 compacte (empreinte verifiee), sinon la copie de
# securite du binaire d'origine.
recover_app() {
  rm -f "$APP.oqc.tmp"
  [ -s "$APP" ] && return 0
  if [ -s "$V15C" ] && [ -s "$V15C.sha256" ]; then
    read -r w _x < "$V15C.sha256"
    if [ "$(sha_of "$V15C")" = "$w" ] && cp "$V15C" "$APP.oqc.tmp" && chmod 755 "$APP.oqc.tmp" && [ "$(sha_of "$APP.oqc.tmp")" = "$w" ] && sync && mv -f "$APP.oqc.tmp" "$APP" && sync; then
      log "REPRISE : $APP absent (coupure pendant le remplacement ?) : OpenQIARA Claude V15 compact remis"; return 0
    fi
  fi
  if [ -s "$OQC/sauvegarde/openqiarad-avant-v15" ] && cp -p "$OQC/sauvegarde/openqiarad-avant-v15" "$APP.oqc.tmp" && sync && mv -f "$APP.oqc.tmp" "$APP" && sync; then
    log "REPRISE : $APP absent : binaire d'origine remis depuis la copie de securite"; return 0
  fi
  rm -f "$APP.oqc.tmp"; log "ECHEC : $APP absent et aucune copie utilisable"; return 1
}

# ---------------------------------------------------------------- 2. binaire
swap_binary() { # remplace le binaire en service (camera sans QIARA Plus) par V15, avec copie de securite sur /media
  p=$(app_pid)
  cp -p "$APP" "$OQC/sauvegarde/openqiarad-avant-v15" 2>/dev/null && sync || { log "ECHEC : copie de securite du binaire en service impossible : rien change"; return 1; }
  log "copie de securite : $OQC/sauvegarde/openqiarad-avant-v15 ($(sha_of "$OQC/sauvegarde/openqiarad-avant-v15" | cut -c1-12))"
  # Arret puis remplacement : la boucle de boot.sh relance /data/openqiarad 10 s apres un arret. Le fichier est retire
  # avant la copie pour liberer sa place (le processus arrete ne le tient plus) : /data ne fait que 20 Mio.
  [ -n "$p" ] && kill "$p" 2>/dev/null
  i=0; while [ -n "$p" ] && [ -d "/proc/$p" ] && [ "$i" -lt 15 ]; do sleep 1; i=$((i + 1)); done
  [ -n "$p" ] && [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
  rm -f "$APP"; sync
  if cp "$V15C" "$APP.oqc.tmp" && chmod 755 "$APP.oqc.tmp" && [ "$(sha_of "$APP.oqc.tmp")" = "$WANTC" ] && sync && mv -f "$APP.oqc.tmp" "$APP" && sync; then
    log "OpenQIARA Claude V15 (version compacte) mis en place sous $APP ; boot.sh le relance"
    return 0
  fi
  rm -f "$APP.oqc.tmp"
  log "ECHEC : copie de V15 impossible (place sur $DATA : $(free_kb "$DATA") Kio) : binaire d'origine remis"
  cp -p "$OQC/sauvegarde/openqiarad-avant-v15" "$APP" && sync
  return 1
}

do_install() {
  mkdir -p "$OQC/sauvegarde"
  log "== installation d'OpenQIARA Claude V15 et de QIARA Plus v10 : debut (uptime $(uptime_s) s)"
  etat "attente-demarrage"
  wait_app 60 "$WAIT_MAX" || { etat "echec : OpenQiara ne tourne pas depuis 60 s apres $WAIT_MAX s d'attente"; return 1; }
  for b in "$V15" "$V15C"; do
    [ -s "$b" ] && [ -s "$b.sha256" ] || { etat "echec : $b ou son empreinte absent"; return 1; }
    read -r w _x < "$b.sha256"; [ "$(sha_of "$b")" = "$w" ] || { etat "echec : empreinte de $b non conforme (copie abimee ?)"; return 1; }
  done
  read -r WANT _x < "$V15.sha256"; read -r WANTC _x < "$V15C.sha256"

  # 2. OpenQIARA Claude V15 en service
  etat "binaire"
  if [ -s "$OQC/openqiara-defauts.json" ] && [ ! -e "$DATA/openqiara-defauts.json.applique" ]; then
    cp "$OQC/openqiara-defauts.json" "$DATA/openqiara-defauts.json" && log "reglages par defaut deposes (fusionnes par OpenQiara a son demarrage, sans ecraser un reglage existant)"
  fi
  if is_launcher; then
    log "QIARA Plus deja installe : la version complete sera mise en essai a l'etape 3"
  else
    cur=$(sha_of "$APP")
    if [ "$cur" = "$WANTC" ] || [ "$cur" = "$WANT" ]; then
      log "V15 deja en service ($APP)"
      if [ -e "$DATA/openqiara-defauts.json" ]; then
        # deposes apres son demarrage : relance pour qu'il les fusionne
        p=$(app_pid); [ -n "$p" ] && kill "$p" 2>/dev/null && log "OpenQiara relance pour fusionner les reglages par defaut"
      fi
    else
      log "binaire en service : $(echo "$cur" | cut -c1-12) ($(wc -c < "$APP") octets) ; V15 compact : $(echo "$WANTC" | cut -c1-12)"
      swap_binary || { etat "echec : binaire non remplace (la camera reste sur sa version d'origine)"; return 1; }
    fi
  fi
  sleep 15
  wait_app 30 300 || { etat "echec : OpenQIARA Claude V15 ne reste pas en marche"; return 1; }
  v="(lanceur QIARA Plus)"; is_launcher || v=$("$APP" -version 2>/dev/null | head -n 1)
  log "OpenQiara en marche (pid $(app_pid)) ; version : ${v:-?}"
  grep -E "installation defaults (applied|not applied)" "$DATA/openqiarad.log" 2>/dev/null | tail -n 1 | cut -c1-240 >> "$LOG"

  # 3. QIARA Plus v10
  if [ "$(conf QIARA_PLUS oui)" = oui ] && ! { is_launcher && [ -f "$DATA/qp/qp-guard" ] && qp_a_jour; }; then
    etat "qiara-plus"
    mkdir -p "$DATA/qp"
    [ -f "$DATA/qp/guard.conf" ] || printf '%s\n' "# Reglages du surveillant QIARA Plus (lignes NOM=valeur ; voir la documentation)." \
      "ENABLE_WIFI_ACTIONS=1" "ENABLE_REBOOT=1" "SSH_SECOURS_PORT=$(conf SSH_SECOURS_PORT 0)" > "$DATA/qp/guard.conf"
    # guard.conf d'une version plus ancienne, sans SSH_SECOURS_PORT : le choix de l'installation y est ajoute
    grep -q '^SSH_SECOURS_PORT=' "$DATA/qp/guard.conf" || echo "SSH_SECOURS_PORT=$(conf SSH_SECOURS_PORT 0)" >> "$DATA/qp/guard.conf"
    is_launcher && [ -f "$DATA/qp/qp-guard" ] && log "QIARA Plus d'une version plus ancienne : outils mis a jour (emplacements et reglages conserves)"
    log "installation de QIARA Plus v10 (qp-setup.sh install --yes, jusqu'a 4 min)"
    if sh "$OQC/qp-setup.sh" install --yes >> "$LOG" 2>&1; then log "QIARA Plus v10 installe"
    else etat "echec : QIARA Plus non installe (retour arriere automatique fait par qp-setup ; OpenQIARA Claude V15 reste en service)"; return 1; fi
  fi
  # 3b. version complete dans l'emplacement new (sur /media), validee par le surveillant apres 3 min de bonne sante et de liaison MQTT
  if is_launcher && [ -f "$DATA/qp/qp-update" ]; then
    etat "version-complete"
    rs=$(cat "$DATA/qp/state/running_slot" 2>/dev/null)
    case "$rs" in factory) rb=$DATA/qp/slots/factory/openqiarad;; good|prev|new) rb=/media/qp/slots/$rs/openqiarad;; *) rb=;; esac
    if [ -n "$rb" ] && [ "$(sha_of "$rb")" = "$WANT" ]; then log "version complete deja en service (emplacement $rs)"
    else
      mkdir -p /media/qp && cp "$V15" /media/qp/incoming.oqc && sh "$DATA/qp/qp-update" stage /media/qp/incoming.oqc "$WANT" >> "$LOG" 2>&1 \
        || { rm -f /media/qp/incoming.oqc; etat "echec : mise en essai de la version complete impossible (la version compacte reste en service)"; return 1; }
      rm -f /media/qp/incoming.oqc
      : > "$DATA/qp/state/expected_stop"; p=$(app_pid); [ -n "$p" ] && kill "$p" 2>/dev/null
      log "version complete en essai (emplacement new) ; attente de sa validation par le surveillant (10 min au plus)"
      i=0; while [ "$i" -lt "${OQC_PROMOTE_MAX:-600}" ] && [ -e "$DATA/qp/state/trial" ]; do sleep 10; i=$((i + 10)); done
      if [ -e "$DATA/qp/state/trial" ]; then log "ATTENTION : essai pas encore valide apres $i s (liaison MQTT ?) : il se poursuit, le surveillant le validera ou l'annulera"
      else log "version complete validee : $(cat /tmp/qp/last_update_result 2>/dev/null)"; fi
    fi
  fi

  # 4. services du cloud
  if [ "$(conf SERVICES_CLOUD neutraliser)" = neutraliser ]; then
    etat "services-cloud"
    if [ -d "$OQC/sauvegarde/services-cloud" ]; then log "services du cloud deja neutralises (copie de securite presente)"
    else sh "$OQC/services-cloud.sh" neutraliser >> "$LOG" 2>&1 || log "ATTENTION : neutralisation des services du cloud incomplete (sans gravite : boot.sh les arrete de toute facon)"; fi
  fi

  # 5. redemarrage
  etat "redemarrage"
  rm -f "$OQC/A-INSTALLER"; : > "$OQC/A-VERIFIER"; sync
  log "installation terminee : redemarrage pour appliquer les reglages video (codec, debit, image cle)"
  if [ -d /tmp/qp/cmd ] && is_launcher; then : > /tmp/qp/cmd/reboot-installation; sleep 60; fi   # par le surveillant (journal, instantane)
  $REBOOT_CMD
}

# ---------------------------------------------------------------- 6. verification
do_verify() {
  log "== verification apres redemarrage (uptime $(uptime_s) s)"
  wait_app 60 "$WAIT_MAX" || log "ATTENTION : OpenQiara pas en marche depuis 60 s"
  sleep 30
  R=$OQC/rapport.txt; ok=1
  {
    echo "Rapport d'installation OpenQIARA Claude V15 / QIARA Plus v10 - $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    p=$(app_pid); [ -n "$p" ] && echo "OK   OpenQiara en marche (pid $p, depuis $(pid_age "$p") s)" || { echo "KO   OpenQiara absent"; ok=0; }
    port80 && echo "OK   interface web : port 80 ouvert" || { echo "KO   port 80 ferme"; ok=0; }
    if is_launcher && [ -f "$DATA/qp/qp-guard" ]; then
      echo "OK   QIARA Plus installe : emplacement en service $(cat "$DATA/qp/state/running_slot" 2>/dev/null)"
      gp=$(cat /tmp/qp/guard.lock/pid 2>/dev/null); [ -n "$gp" ] && [ -d "/proc/$gp" ] && echo "OK   surveillant en marche (pid $gp)" || { echo "KO   surveillant absent"; ok=0; }
    elif [ "$(conf QIARA_PLUS oui)" = oui ]; then echo "KO   QIARA Plus non installe"; ok=0
    else echo "--   QIARA Plus non demande"; fi
    hl=; for q in /proc/[0-9]*; do [ "$(cat "$q/comm" 2>/dev/null)" = hlcamd ] && hl=$(tr '\0' ' ' < "$q/cmdline"); done
    [ -n "$hl" ] && echo "OK   hlcamd : $(echo "$hl" | grep -oE -- '--(use-h26[45]|1080p-bitrate [0-9]+|gop-denum [0-9]+|iv-detection [01])' | tr '\n' ' ')" || { echo "KO   hlcamd absent"; ok=0; }
    # liaison MQTT : etat publie par OpenQiara pour le surveillant (mqtt=1 connecte), sinon le journal
    m=$(sed -n 's/^mqtt=//p' /tmp/qp/health 2>/dev/null | head -n 1)
    if [ "$m" = 1 ]; then echo "OK   liaison MQTT etablie (Home Assistant)"
    elif [ "$m" = 0 ]; then echo "KO   liaison MQTT coupee : adresse, compte ou mot de passe du courtier ? ($(grep -iE 'mqtt' "$DATA/openqiarad.log" 2>/dev/null | grep -iE 'error|fail|refused|not authori' | tail -n 1 | cut -c1-160))"; ok=0
    elif grep -q 'mqtt connected' "$DATA/openqiarad.log" 2>/dev/null; then echo "OK   liaison MQTT etablie (journal)"
    else echo "KO   aucune liaison MQTT vue dans le journal (courtier joignable ? adresse, compte ?)"; ok=0; fi
    [ -e "$DATA/qp/state/trial" ] && { echo "KO   version complete encore en essai, non validee par le surveillant (liaison MQTT ?)"; ok=0; }
    echo "--   configuration video : $(tr -d '\n' < "$DATA/openqiara.json" 2>/dev/null | grep -oE '"video"[[:space:]]*:[[:space:]]*\{[^}]*\}' | tr -s ' ')"
    [ -e "$DATA/openqiara-defauts.json.applique" ] && echo "OK   reglages par defaut appliques" || { [ -e "$DATA/openqiara-defauts.json" ] && { echo "KO   reglages par defaut pas encore appliques"; ok=0; }; }
    [ -d "$OQC/sauvegarde/services-cloud" ] && echo "OK   services du cloud neutralises (retour : sh $OQC/services-cloud.sh retour)" || echo "--   services du cloud non neutralises"
    echo "--   place libre : /data $(free_kb "$DATA") Kio, /media $(free_kb /media) Kio"
    echo
    [ "$ok" = 1 ] && echo "RESULTAT : installation reussie" || echo "RESULTAT : a verifier (voir $LOG)"
  } > "$R.tmp" 2>&1
  mv -f "$R.tmp" "$R"; cat "$R" >> "$LOG"
  rm -f "$OQC/A-VERIFIER"; sync
  [ "$ok" = 1 ] && etat "termine" || etat "termine avec reserves (voir $R)"
}

case "${1:-auto}" in
  etat)     cat "$ETAT" 2>/dev/null || echo "(pas d'installation)"; [ -f "$OQC/rapport.txt" ] && { echo; cat "$OQC/rapport.txt"; }
            [ -d "$LOCK" ] && echo "(installer.sh en cours ; journal : $LOG)"; exit 0 ;;
  auto|verifier) ;;
  *)        echo "usage : sh installer.sh [auto|verifier|etat]"; exit 2 ;;
esac
# verrou : un seul installer.sh a la fois ; un verrou laisse par un installeur tue (pid disparu) est repris
if ! mkdir "$LOCK" 2>/dev/null; then
  lp=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$lp" ] && [ -d "/proc/$lp" ]; then echo "installer.sh tourne deja (pid $lp)"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { echo "verrou $LOCK impossible"; exit 1; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
recover_app
case "$1" in
  verifier) do_verify ;;
  *)        if [ -e "$OQC/A-INSTALLER" ]; then do_install; elif [ -e "$OQC/A-VERIFIER" ]; then do_verify; fi ;;
esac
