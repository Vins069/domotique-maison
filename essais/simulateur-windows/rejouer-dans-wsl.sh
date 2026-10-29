#!/usr/bin/env bash
# rejouer-dans-wsl.sh : seconde moitie du simulateur Windows. Rejoue, sur Linux, EXACTEMENT ce que Preparer-carte-SD.ps1
# a transmis a WSL pendant un scenario du simulateur (dossier courant --cd, arguments, fichier de configuration tel
# qu'ecrit par PowerShell : UTF-8 avec BOM, fins de ligne CRLF), dans un environnement qui imite WSL :
#   - les chemins /mnt/c/... existent (paquet decompresse, cle publique, configuration), droits ouverts comme DrvFs ;
#   - la carte est un vrai disque /dev/sdX avec ses partitions /dev/sdX1..3 (noeuds poses sur des peripheriques de
#     boucle d'une image de carte d'origine), comme le lecteur USB rattache par usbipd ;
#   - l'outil tourne en root (wsl -u root) et recoit « o » a sa question de confirmation (saisie de l'utilisateur).
# Usage (root) : bash rejouer-dans-wsl.sh <dossier captures du scenario> <paquet.zip> <carte-origine.img> <carte-sortie.img>
set -euo pipefail
CAP=$1; ZIP=$2; ORIG=$3; OUT=$4
[ "$(id -u)" = 0 ] || { echo "lancer en root"; exit 1; }
CMD="$CAP/preparer-carte-sd.sh-commande.txt"; CONFCAP="$CAP/preparer-carte-sd.sh-configuration.txt"
[ -f "$CMD" ] && [ -f "$CONFCAP" ] || { echo "captures absentes dans $CAP"; exit 1; }
mapfile -t L < <(tr -d '\r' < "$CMD")
CD=${L[0]}; [ "${L[1]}" = ./preparer-carte-sd.sh ] || { echo "commande inattendue : ${L[1]}"; exit 1; }
ARGS=("${L[@]:2}")
CONF=""; DISQUE=""
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in --configuration) CONF=${ARGS[$((i + 1))]};; --disque) DISQUE=${ARGS[$((i + 1))]};; esac
done
echo "== commande transmise par Windows : cd $CD ; bash ./preparer-carte-sd.sh ${ARGS[*]}"
case "$CD$CONF" in /mnt/c/*/mnt/c/*) ;; *) echo "chemins inattendus (pas sous /mnt/c)"; exit 1;; esac
[ -n "$DISQUE" ] || { echo "--disque absent"; exit 1; }

# --- arborescence /mnt/c imitant le disque Windows vu par WSL
nettoyer() {
  for n in "" 1 2 3; do rm -f "/dev/$DISQUE$n"; done
  for b in ${BOUCLES:-}; do losetup -d "$b" 2>/dev/null || true; done
}
BOUCLES=""; trap nettoyer EXIT
mkdir -p "$(dirname "$CD")" "$(dirname "$CONF")"
rm -rf "$CD"; (cd "$(dirname "$CD")" && unzip -q -o "$ZIP")
[ -f "$CD/preparer-carte-sd.sh" ] || { echo "paquet non trouve sous $CD"; exit 1; }
cp "$CONFCAP" "$CONF"
CLE=$(sed -e 's/^\xEF\xBB\xBF//' -e 's/\r$//' "$CONF" | sed -n 's/^CLE_SSH_PUBLIQUE=//p' | tail -n 1)
mkdir -p "$(dirname "$CLE")"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISIMULATEURWINDOWSOPENQIARAV15xxxxxxxxxx simulateur@windows\n' > "$CLE"
chmod -R a+rwX /mnt/c   # DrvFs : fichiers Windows ouverts a tous dans WSL (pas de metadonnees)
echo "   configuration : $CONF ($(head -c 3 "$CONF" | od -An -tx1 | tr -d ' ') en tete, $(grep -c $'\r$' "$CONF") lignes CRLF)"
echo "   cle publique  : $CLE"

# --- la carte : /dev/<disque> et /dev/<disque>1..3, comme un lecteur USB rattache a WSL
for n in "" 1 2 3; do [ ! -e "/dev/$DISQUE$n" ] || { echo "/dev/$DISQUE$n existe deja ici : abandon"; exit 1; }; done
cp "$ORIG" "$OUT"
b=$(losetup -f --show "$OUT"); BOUCLES="$b"
mknod "/dev/$DISQUE" b 7 "$(cat /sys/block/$(basename "$b")/dev | cut -d: -f2)"
while read -r nr debut secteurs; do
  b=$(losetup -f --show -o $((debut * 512)) --sizelimit $((secteurs * 512)) "$OUT"); BOUCLES="$BOUCLES $b"
  mknod "/dev/$DISQUE$nr" b 7 "$(cat /sys/block/$(basename "$b")/dev | cut -d: -f2)"
done < <(partx -g -o NR,START,SECTORS "$OUT")
ls -l /dev/"$DISQUE"* | awk '{print "   " $1, $5, $6, $NF}'

# --- l'outil, tel que lance par wsl.exe -u root --cd <ici> -e bash ./preparer-carte-sd.sh ...
echo "== preparer-carte-sd.sh (reponse « o » a la confirmation)"
set +e
( cd "$CD" && HOME=/root printf 'o\n' | HOME=/root bash ./preparer-carte-sd.sh "${ARGS[@]}" )
rc=$?
set -e
echo "== code de sortie : $rc"
sync
exit $rc
