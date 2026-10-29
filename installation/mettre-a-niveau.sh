#!/usr/bin/env bash
# mettre-a-niveau.sh : passe une camera Qiara qui fait deja tourner OpenQiara a OpenQIARA Claude V15 et QIARA Plus v10,
# par SSH, sans demonter la carte. Les capteurs appaires, la configuration MQTT et les reglages restent.
#   ./mettre-a-niveau.sh [--configuration configuration.txt] [--camera 192.168.1.50] [--oui] [--essai]
# Prerequis : la cle SSH de CLE_SSH_PUBLIQUE autorisee sur la camera (sa cle privee a cote, meme nom sans .pub).
# Deroulement :
#   1. controles en lecture seule (processeur, OpenQiara en marche lance par boot.sh, place sur /data et /media) ;
#   2. sauvegarde sur l'ordinateur de /data/openqiara.json, boot.sh et post_boot.sh (./sauvegarde-camera-<date>/) ;
#   3. depot du paquet dans /media/oqc, empreintes verifiees sur la camera ;
#   4. boot.sh remplace par celui de la distribution (copie .avant-v15 gardee), bloc ajoute a post_boot.sh ;
#   5. installer.sh lance sur la camera : V15, QIARA Plus, services du cloud, redemarrage, verification ;
#   6. suivi jusqu'au rapport final.
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
. "$ICI/commun.sh"
CONF="$ICI/configuration.txt"; PAQUET="$ICI/camera"; OUI=0; ESSAI=0; CAM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --configuration) CONF=$2; shift 2;;
    --camera) CAM=$2; shift 2;;
    --paquet) PAQUET=$2; shift 2;;
    --oui) OUI=1; shift;;
    --essai) ESSAI=1; shift;;
    -h|--aide) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) err "option inconnue : $1";;
  esac
done
msg "=== OpenQIARA Claude V15 : mise a niveau par SSH ==="
cfg_charger "$CONF"; cfg_verifier ssh
[ -n "$CAM" ] || CAM=$(cfg CAMERA_ADRESSE "")
[ -n "$CAM" ] || err "CAMERA_ADRESSE est vide (ou --camera <adresse>)"
[ -n "$CLE" ] || err "CLE_SSH_PUBLIQUE est vide"
PRIV=${CLE%.pub}; [ -f "$PRIV" ] || err "cle privee introuvable a cote de la cle publique : $PRIV"
paquet_verifier "$PAQUET"
# Cles d'hote de la camera : fichier dedie (premiere connexion acceptee, puis verifiee). Sur certaines installations,
# dropbear regenere ses cles a chaque demarrage (dans /tmp) : apres le redemarrage de fin d'installation, la nouvelle cle
# est acceptee une seule fois, avec un message (rien n'est envoye a la camera apres le redemarrage, on ne fait que lire).
KH="$ICI/.cles-hote-camera-$(printf '%s' "$CAM" | tr -c 'A-Za-z0-9.' '_')"
SSH_OPTS=(-i "$PRIV" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KH" -o LogLevel=ERROR ${OQC_SSH_OPTS:-})
cam() { ssh "${SSH_OPTS[@]}" "root@$CAM" "$@"; }
envoyer() { cam "cat > '$2.part' && mv -f '$2.part' '$2'" < "$1"; }

# ---------------------------------------------------------------- 1. controles
if ! o=$(cam true 2>&1); then
  if printf '%s' "$o" | grep -q 'HOST IDENTIFICATION HAS CHANGED'; then
    err "la cle d'hote SSH de $CAM a change depuis le dernier passage (camera reinstallee, ou cles regenerees a chaque demarrage) ; si c'est bien votre camera, effacer $KH puis relancer"
  fi
  err "connexion SSH a root@$CAM impossible avec $PRIV : $(printf '%s' "$o" | tail -n 1)"
fi
rm -f "$KH.renouvelee"; ok "connexion SSH a $CAM"
R=$(cam 'uname -m; [ -f /data/boot.sh ] && echo boot=1 || echo boot=0; [ -f /data/openqiara.json ] && echo conf=1 || echo conf=0
  p=; for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = openqiarad ] && p=${d#/proc/} && break; done; echo "pid=$p"
  [ -n "$p" ] && pp=$(awk "/^PPid:/{print \$2}" /proc/$p/status) && tr "\0" " " < /proc/$pp/cmdline | grep -q boot.sh && echo boucle=1 || echo boucle=0
  [ "$(head -c 2 /data/openqiarad 2>/dev/null)" = "#!" ] && echo qp=1 || echo qp=0
  df -k /data | awk "NR==2{print \"data=\" \$4}"; df -k /media | awk "NR==2{print \"media=\" \$4}"
  [ -e /media/oqc/A-INSTALLER ] && echo encours=1 || echo encours=0')
val() { printf '%s\n' "$R" | sed -n "s/^$1=//p" | head -n 1; }
# configuration en service (lue, jamais modifiee ici) : HomeKit actif et codec deja choisi
JSON=$(cam 'tr -d "\n" < /data/openqiara.json 2>/dev/null' || true)
HK_ACTIF=0; printf '%s' "$JSON" | grep -oE '"homekit"[[:space:]]*:[[:space:]]*\{[^}]*\}' | grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' && HK_ACTIF=1
CODEC_CAM=$(printf '%s' "$JSON" | grep -oE '"video"[[:space:]]*:[[:space:]]*\{[^}]*\}' | grep -oE '"codec"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)
DEJA_DEFAUTS=$(cam '[ -e /data/openqiara-defauts.json.applique ] && echo 1 || echo 0' 2>/dev/null || echo 0)
[ "$(printf '%s\n' "$R" | head -n 1)" = armv7l ] || err "la machine $CAM n'est pas une camera Qiara (processeur $(printf '%s\n' "$R" | head -n 1))"
[ "$(val boot)" = 1 ] && [ "$(val conf)" = 1 ] || err "/data/boot.sh ou /data/openqiara.json absent : OpenQiara n'est pas installe ; preparer la carte SD (preparer-carte-sd.sh)"
[ -n "$(val pid)" ] || err "OpenQiara ne tourne pas sur la camera"
[ "$(val boucle)" = 1 ] || [ "$(val qp)" = 1 ] || err "OpenQiara n'est pas lance par la boucle de /data/boot.sh : installation non standard, mise a niveau automatique impossible"
[ "$(val encours)" = 0 ] || err "une installation est deja en cours sur la camera (/media/oqc/A-INSTALLER) : voir sh /media/oqc/installer.sh etat"
[ "${OQC_SANS_CONTROLE_PLACE:-0}" = 1 ] || { [ "$(val media)" -ge 60000 ] || err "/media : $(val media) Kio libres, 60000 necessaires"; }
if [ "$HK_ACTIF" = 1 ] && [ "$CODEC" = h265 ] && [ -z "$CODEC_CAM" ]; then
  err "HomeKit est actif sur cette camera et n'accepte que le H.264 : mettre CODEC=h264 dans la configuration (ou couper HomeKit dans l'interface web de la camera), puis relancer"
fi
[ "$HK_ACTIF" = 1 ] && [ -n "$CODEC_CAM" ] && [ "$CODEC_CAM" != h264 ] && info "HomeKit est actif mais la camera est reglee en $CODEC_CAM : la camera HomeKit restera inactive tant que le codec n'est pas h264"
[ -n "$CODEC_CAM" ] && [ "$CODEC_CAM" != "$CODEC" ] && info "codec deja choisi sur la camera ($CODEC_CAM) : il est garde (CODEC=$CODEC ne s'applique qu'a une camera sans choix ; pour changer : sh /media/oqc/reglage.sh codec $CODEC)"
[ "$DEJA_DEFAUTS" = 1 ] && info "reglages video deja installes une premiere fois : ceux de la configuration ne sont pas reappliques (pour en changer : sh /media/oqc/reglage.sh, voir LISEZ-MOI)"
ok "camera sous OpenQiara (pid $(val pid)), QIARA Plus $( [ "$(val qp)" = 1 ] && echo deja installe || echo absent), place : /data $(val data) Kio, /media $(val media) Kio"
[ "$ESSAI" = 1 ] && { msg "=== essai : controles reussis, rien n'a ete ecrit ==="; exit 0; }
if [ "$OUI" != 1 ]; then
  printf 'Mettre la camera %s a niveau (elle redemarrera une fois) ? [o/N] ' "$CAM"; read -r r
  case "$r" in [oOyY]*) ;; *) msg "abandon, rien n'a ete ecrit"; exit 1;; esac
fi

# ---------------------------------------------------------------- 2. sauvegarde
SAUV="$PWD/sauvegarde-camera-$(date +%Y%m%d-%H%M%S)"
( umask 077; mkdir -p "$SAUV" )   # openqiara.json contient le mot de passe MQTT
for f in openqiara.json boot.sh post_boot.sh; do ( umask 077; cam "cat /data/$f 2>/dev/null" > "$SAUV/$f" ) || true; done
[ -s "$SAUV/openqiara.json" ] || err "sauvegarde de /data/openqiara.json impossible : rien n'a ete ecrit"
chmod 600 "$SAUV/openqiara.json"
ok "sauvegarde : $SAUV (openqiara.json contient le mot de passe MQTT : a garder pour soi)"

# ---------------------------------------------------------------- 3. paquet dans /media/oqc
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fichier_defauts "$TMP/openqiara-defauts.json"; fichier_installation "$TMP/installation.conf"
for f in openqiarad-claude-v15 openqiarad-claude-v15-compact; do printf '%s  %s\n' "$(sha256_de "$PAQUET/$f")" "$f" > "$TMP/$f.sha256"; done
cam 'mkdir -p /media/oqc/sauvegarde'
for f in openqiarad-claude-v15 openqiarad-claude-v15-compact qp-setup.sh installer.sh services-cloud.sh reglage.sh boot.sh; do envoyer "$PAQUET/$f" "/media/oqc/$f"; done
for f in openqiarad-claude-v15.sha256 openqiarad-claude-v15-compact.sha256 openqiara-defauts.json installation.conf; do envoyer "$TMP/$f" "/media/oqc/$f"; done
for f in openqiarad-claude-v15 openqiarad-claude-v15-compact qp-setup.sh installer.sh services-cloud.sh reglage.sh boot.sh; do
  [ "$(cam "sha256sum /media/oqc/$f" | cut -d' ' -f1)" = "$(sha256_de "$PAQUET/$f")" ] || err "/media/oqc/$f abime pendant l'envoi : relancer"
done
cam 'chmod 755 /media/oqc/*.sh /media/oqc/openqiarad-claude-v15 /media/oqc/openqiarad-claude-v15-compact'
ok "paquet depose dans /media/oqc, empreintes verifiees sur la camera"

# ---------------------------------------------------------------- 4. boot.sh et post_boot.sh
bloc_post_boot > "$TMP/post_boot-bloc.txt"; envoyer "$TMP/post_boot-bloc.txt" /media/oqc/post_boot-bloc.txt
cam 'set -e
  if ! cmp -s /media/oqc/boot.sh /data/boot.sh; then
    [ -e /data/boot.sh.avant-v15 ] || cp -p /data/boot.sh /data/boot.sh.avant-v15
    cp /media/oqc/boot.sh /data/boot.sh.oqc.tmp && chmod 755 /data/boot.sh.oqc.tmp && sync && mv -f /data/boot.sh.oqc.tmp /data/boot.sh && sync
    echo "boot.sh remplace (copie /data/boot.sh.avant-v15)"
  fi
  [ -f /data/post_boot.sh ] || echo "# /data/post_boot.sh : reglages locaux, execute par boot.sh a la fin du demarrage." > /data/post_boot.sh
  if ! grep -qF "$(head -n 1 /media/oqc/post_boot-bloc.txt)" /data/post_boot.sh; then
    cp -p /data/post_boot.sh /data/post_boot.sh.avant-v15
    # bloc place en tete (apres une eventuelle ligne #!) : un « exit » plus bas dans le fichier ne l empeche pas de s executer
    { if head -n 1 /data/post_boot.sh | grep -q "^#!"; then head -n 1 /data/post_boot.sh; cat /media/oqc/post_boot-bloc.txt; echo; tail -n +2 /data/post_boot.sh
      else cat /media/oqc/post_boot-bloc.txt; echo; cat /data/post_boot.sh; fi; } > /data/post_boot.sh.oqc.tmp
    if ! sh -n /data/post_boot.sh.oqc.tmp; then rm -f /data/post_boot.sh.oqc.tmp; echo "ECHEC post_boot.sh modifie invalide"; exit 3; fi
    mv -f /data/post_boot.sh.oqc.tmp /data/post_boot.sh && sync
    echo "bloc place en tete de post_boot.sh (copie /data/post_boot.sh.avant-v15)"
  fi' | sed 's/^/  ok    /' || err "modification de boot.sh ou de post_boot.sh en echec (voir ci-dessus) : installation non lancee (copies .avant-v15 sur la camera, sauvegarde : $SAUV)"

# ---------------------------------------------------------------- 5. installation sur la camera
cam ': > /media/oqc/A-INSTALLER; rm -f /media/oqc/A-VERIFIER /media/oqc/rapport.txt /media/oqc/etat; sync; ( setsid nohup sh /media/oqc/installer.sh auto >/dev/null 2>&1 < /dev/null & )'
ok "installation lancee sur la camera (journal : /media/oqc/installation.log)"

# ---------------------------------------------------------------- 6. suivi
msg "suivi (10 a 20 min ; la camera redemarre une fois) :"
lire_etat() { # etat de l'installation ; accepte une fois une nouvelle cle d'hote apres le redemarrage
  local o
  o=$(cam 'cat /media/oqc/etat 2>/dev/null || echo "(installation en preparation)"' 2>&1) && { printf '%s' "$o"; return; }
  if printf '%s' "$o" | grep -q 'HOST IDENTIFICATION HAS CHANGED' && [ ! -e "$KH.renouvelee" ] && [ "${vu_redemarrage:-0}" = 1 ]; then
    : > "$KH.renouvelee"; rm -f "$KH"
    info "la cle d'hote SSH de la camera a change au redemarrage (cles regenerees a chaque demarrage sur cette camera) : nouvelle cle acceptee" >&2
    o=$(cam 'cat /media/oqc/etat 2>/dev/null || echo "(installation en preparation)"' 2>&1) && { printf '%s' "$o"; return; }
  fi
  printf '%s' "(camera injoignable : redemarrage en cours ?)"
}
dernier=""; t0=$(date +%s); limite=$(( t0 + ${OQC_SUIVI_MAX:-2400} ))
while [ "$(date +%s)" -lt "$limite" ]; do
  e=$(lire_etat)
  case "$e" in redemarrage|*injoignable*) vu_redemarrage=1;; esac
  [ "$e" != "$dernier" ] && { info "$(( $(date +%s) - t0 )) s : $e"; dernier=$e; }
  case "$e" in termine*) break;; echec*) break;; esac
  sleep 15
done
msg ""
cam 'cat /media/oqc/rapport.txt 2>/dev/null || tail -n 30 /media/oqc/installation.log' || msg "camera injoignable : relancer plus tard « ssh root@$CAM sh /media/oqc/installer.sh etat »"
case "$dernier" in termine) msg "=== mise a niveau terminee ===";; *) msg "=== mise a niveau : etat « $dernier » (voir ci-dessus) ==="; exit 1;; esac
