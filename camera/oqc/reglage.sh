#!/bin/sh
# reglage.sh : change un reglage video d'OpenQIARA Claude V15 apres l'installation (par SSH sur la camera).
#   sh /media/oqc/reglage.sh codec h264|h265
#   sh /media/oqc/reglage.sh debit 2500000              (bits/s, de 500000 a 8000000)
#   sh /media/oqc/reglage.sh image-cle 1|2              (1 = une image cle par seconde, 2 = toutes les 0,5 s)
#   sh /media/oqc/reglage.sh detection oui|non          (detection de personnes de la camera)
#   sh /media/oqc/reglage.sh reglages-image deverrouilles|verrouilles   (luminosite, saturation... depuis Home Assistant)
# Ajouter --sans-redemarrage en dernier pour ne pas redemarrer (le reglage video s'applique alors au prochain demarrage).
# Fonctionnement : le reglage est ecrit dans /data/openqiara-reglages.json, OpenQiara le lit a son demarrage, le reporte
# dans sa configuration (ecriture atomique) et met le fichier de cote ; la camera redemarre ensuite pour que boot.sh
# relance hlcamd avec le nouveau reglage. Aucune edition du fichier de configuration a la main.
set -u
DATA=${OQC_DATA:-/data}
F=$DATA/openqiara-reglages.json
REBOOT_CMD=${OQC_REBOOT:-reboot}
app_pid() { for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = openqiarad ] && { echo "${p#/proc/}"; return 0; }; done; return 1; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
num() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
[ $# -ge 2 ] || usage
NOM=$1; VAL=$2; REBOOT=1; [ "${3:-}" = --sans-redemarrage ] && REBOOT=0
case "$NOM" in
  codec)          case "$VAL" in h264|h265) J="{\"video\":{\"codec\":\"$VAL\"}}";; *) usage;; esac
                  # HomeKit n'accepte que le H.264 : avec HomeKit actif, le H.265 ferait disparaitre la camera d'Apple Maison
                  if [ "$VAL" = h265 ] && tr -d '\n' < "$DATA/openqiara.json" 2>/dev/null | grep -oE '"homekit"[[:space:]]*:[[:space:]]*\{[^}]*\}' | grep -qE '"enabled"[[:space:]]*:[[:space:]]*true'; then
                    echo "refuse : HomeKit est actif et n'accepte que le H.264 (couper HomeKit dans l'interface web, puis relancer)"; exit 2
                  fi ;;
  debit)          num "$VAL" 500000 8000000 || { echo "debit : de 500000 a 8000000 bits/s"; exit 2; }; J="{\"video\":{\"bitrate\":$VAL}}" ;;
  # image-cle : l'option --gop-denum N de hlcamd donne un groupe de 30/N images, soit une image cle toutes les 1/N s
  # (mesure : 1 -> 1 s, 2 -> 0,5 s). Au-dela de 2, les images cles mangent le debit sans gain : seuls 1 et 2 sont proposes.
  image-cle)      num "$VAL" 1 2 || { echo "image-cle : 1 (une image cle par seconde) ou 2 (toutes les 0,5 s)"; exit 2; }; J="{\"video\":{\"gop_denum\":$VAL}}" ;;
  detection)      case "$VAL" in oui) J='{"video":{"iv_detection":true}}';; non) J='{"video":{"iv_detection":false}}';; *) usage;; esac ;;
  reglages-image) case "$VAL" in deverrouilles) J='{"video":{"lock":false}}';; verrouilles) J='{"video":{"lock":true}}';; *) usage;; esac
                  REBOOT=0 ;;   # lu par OpenQiara seul : sa relance suffit
  *) usage ;;
esac
[ -e "$F" ] && { echo "un changement est deja en attente ($F) : attendre son application"; exit 1; }
printf '%s\n' "$J" > "$F.tmp" && mv -f "$F.tmp" "$F" && sync || { echo "ECHEC : ecriture de $F impossible"; exit 1; }
rm -f "$F.applique" "$F.refuse"
echo "reglage demande : $NOM = $VAL"
# relance d'OpenQiara (QIARA Plus : arret annonce, le lanceur le relance ; sinon la boucle de boot.sh, 10 s apres)
p=$(app_pid)
[ -d "$DATA/qp/state" ] && : > "$DATA/qp/state/expected_stop"
[ -n "$p" ] && kill "$p" 2>/dev/null && echo "OpenQiara (pid $p) relance pour lire le reglage"
i=0; while [ "$i" -lt 90 ] && [ ! -e "$F.applique" ] && [ ! -e "$F.refuse" ]; do sleep 2; i=$((i + 2)); done
if [ -e "$F.applique" ]; then echo "reglage enregistre par OpenQiara"
elif [ -e "$F.refuse" ]; then echo "ECHEC : reglage refuse par OpenQiara (voir /data/openqiarad.log)"; exit 1
else echo "ATTENTION : OpenQiara n'a pas encore lu le reglage apres 90 s (il le lira a son prochain demarrage)"; exit 1; fi
if [ "$REBOOT" = 1 ]; then
  echo "redemarrage de la camera dans 5 s (boot.sh relance hlcamd avec le nouveau reglage)"
  sleep 5; sync
  if [ -d /tmp/qp/cmd ]; then : > /tmp/qp/cmd/reboot-reglage; sleep 60; fi
  $REBOOT_CMD
fi
