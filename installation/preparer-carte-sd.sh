#!/usr/bin/env bash
# preparer-carte-sd.sh : prepare hors ligne la carte microSD d'une camera Qiara pour OpenQIARA Claude V15 et QIARA Plus v10.
# Fonctionne sous Linux, sous macOS (e2fsprogs de Homebrew) et sous Windows dans WSL (voir Preparer-carte-SD.ps1).
#
#   sudo ./preparer-carte-sd.sh --disque sdb  [--configuration configuration.txt] [--oui]
#   sudo ./preparer-carte-sd.sh --disque disk4 ...          (macOS : identifiant donne par « diskutil list »)
#   (sous Windows : Preparer-carte-SD.ps1, qui confie le lecteur de carte a WSL par usbipd-win)
#   sudo ./preparer-carte-sd.sh --image carte.img ...       (image complete de la carte, pour essai)
#        --essai          controle tout, n'ecrit rien
#        --remplacer      accepte une carte qui porte deja OpenQiara (sa configuration est sauvegardee puis remplacee ;
#                         pour garder capteurs et reglages, preferer mettre-a-niveau.sh par SSH)
#
# Ce qui est ecrit (rien d'autre n'est touche) :
#   p1 (systeme)  /etc/init.d/rcS.real : lancement de /data/boot.sh au demarrage, journal ext4 garde sur /data
#                 (memes correctifs que l'outil d'origine du projet OpenQiara) ;
#   p2 (/data)    reformatee, puis : OpenQIARA Claude V15 (version compacte), boot.sh, Wi-Fi, cle SSH, configuration,
#                 reglages par defaut, post_boot.sh ; l'appairage radio d'origine (fbxhome.xml*) et les fichiers du
#                 constructeur (iv_license, passphrase, video.key, ssl/, hlcamd-parameters.json, firmwares/) sont recopies ;
#   p3 (/media)   dossier /media/oqc : de quoi terminer l'installation au premier demarrage (installer.sh, QIARA Plus,
#                 version complete d'OpenQIARA Claude V15). Le reste de /media n'est pas touche.
# Avant toute ecriture, une sauvegarde est faite dans ./sauvegarde-carte-<date>/ : image complete de /data et rcS.real.
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
. "$ICI/commun.sh"

DISQUE=""; IMAGE=""; CONF="$ICI/configuration.txt"; PAQUET="$ICI/camera"; OUI=0; ESSAI=0; REMPLACER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --disque) DISQUE=$2; shift 2;;
    --image) IMAGE=$2; shift 2;;
    --configuration) CONF=$2; shift 2;;
    --paquet) PAQUET=$2; shift 2;;
    --oui) OUI=1; shift;;
    --essai) ESSAI=1; shift;;
    --remplacer) REMPLACER=1; shift;;
    -h|--aide) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) err "option inconnue : $1 (voir --aide)";;
  esac
done
[ -n "$DISQUE" ] || [ -n "$IMAGE" ] || err "indiquer --disque <nom> (sdb, mmcblk0, disk4) ou --image <fichier>"
DISQUE=${DISQUE#/dev/}; DISQUE=${DISQUE#r}   # « /dev/sdb » ou « rdisk4 » acceptes
case "$DISQUE" in */*) err "--disque : le nom du disque seul (sdb, mmcblk0, disk4), lu : $DISQUE";; esac

# ---------------------------------------------------------------- outils e2fsprogs
OUTILS=""
if [ "$(uname -s)" = Darwin ]; then
  # e2fsprogs de Homebrew n'est pas lie dans le PATH ; « brew » refuse de tourner sous sudo : chemins connus d'abord
  for d in /opt/homebrew/opt/e2fsprogs/sbin /usr/local/opt/e2fsprogs/sbin; do [ -x "$d/debugfs" ] && { OUTILS=$d; break; }; done
  [ -n "$OUTILS" ] || OUTILS="$(sudo -u "${SUDO_USER:-$USER}" brew --prefix e2fsprogs 2>/dev/null)/sbin"
fi
outil() { if [ -n "$OUTILS" ] && [ -x "$OUTILS/$1" ]; then echo "$OUTILS/$1"; elif command -v "$1" >/dev/null 2>&1; then command -v "$1"; elif [ -x "/sbin/$1" ]; then echo "/sbin/$1"; else echo ""; fi; }
DEBUGFS=$(outil debugfs); MKE2FS=$(outil mke2fs); E2FSCK=$(outil e2fsck); DUMPE2FS=$(outil dumpe2fs)
existe() { "$DEBUGFS" -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; }   # debugfs rend 0 meme sur un fichier absent
[ -n "$DEBUGFS" ] && [ -n "$MKE2FS" ] && [ -n "$E2FSCK" ] && [ -n "$DUMPE2FS" ] || err "outils ext4 introuvables (debugfs, mke2fs, e2fsck). Linux/WSL : sudo apt install e2fsprogs ; macOS : brew install e2fsprogs"

msg "=== OpenQIARA Claude V15 : preparation de la carte SD ==="
cfg_charger "$CONF"; cfg_verifier carte
ok "configuration lue : Wi-Fi « $WIFI_SSID », MQTT $MQTT_SERVEUR:$MQTT_PORT, $CODEC a $DEBIT bit/s, image cle reglage $IMAGE_CLE (1 = chaque seconde), QIARA Plus $QIARA_PLUS"
paquet_verifier "$PAQUET"

# ---------------------------------------------------------------- partitions
BOUCLES=""
fin() { local r=$?; [ -n "${TMP:-}" ] && rm -rf "$TMP"; for b in $BOUCLES; do losetup -d "$b" 2>/dev/null; done; exit $r; }
trap fin EXIT
TMP=$(mktemp -d)
if [ -n "$IMAGE" ]; then
  # image d'une carte : une boucle par partition, d'apres sa table (partx), sans dependre de la lecture des partitions par le noyau
  [ -f "$IMAGE" ] || err "image introuvable : $IMAGE"
  [ "$(id -u)" = 0 ] || err "lancer avec sudo (peripheriques de boucle)"
  command -v partx >/dev/null 2>&1 && command -v losetup >/dev/null 2>&1 || err "partx et losetup necessaires (paquet util-linux)"
  TABLE=$(partx -g -o NR,START,SECTORS "$IMAGE" 2>/dev/null) || err "table des partitions illisible dans $IMAGE"
  for n in 1 2 3; do
    l=$(printf '%s\n' "$TABLE" | awk -v n=$n '$1==n {print $2, $3}')
    [ -n "$l" ] || err "partition $n absente de $IMAGE"
    b=$(losetup -f --show -o $(( ${l% *} * 512 )) --sizelimit $(( ${l#* } * 512 )) "$IMAGE") || err "boucle impossible (partition $n)"
    BOUCLES="$BOUCLES $b"; eval "P$n=$b"
  done
else
  case "$DISQUE" in
    disk[0-9]*) P1=/dev/${DISQUE}s1; P2=/dev/${DISQUE}s2; P3=/dev/${DISQUE}s3 ;;
    *[0-9])     P1=/dev/${DISQUE}p1; P2=/dev/${DISQUE}p2; P3=/dev/${DISQUE}p3 ;;
    *)          P1=/dev/${DISQUE}1; P2=/dev/${DISQUE}2; P3=/dev/${DISQUE}3 ;;
  esac
  [ "$(id -u)" = 0 ] || err "lancer avec sudo pour lire et ecrire /dev/$DISQUE"
  for p in "$P1" "$P2" "$P3"; do
    [ -b "$p" ] || err "$p absent : est-ce bien la carte de la camera (3 partitions) ? Lister : lsblk (Linux) ou diskutil list (macOS)"
  done
fi
for p in "$P1" "$P2" "$P3"; do [ -e "$p" ] || err "$p absent"; done

# Une carte Qiara : p1 porte le systeme du constructeur (rcS.real, hlcamd), p2 est petite (environ 20 Mio).
existe "$P1" /etc/init.d/rcS.real || err "$P1 ne contient pas /etc/init.d/rcS.real : ce n'est pas la carte d'une camera Qiara"
existe "$P1" /usr/bin/hlcamd || err "$P1 ne contient pas hlcamd : ce n'est pas la carte d'une camera Qiara"
BLOCS2=$("$DUMPE2FS" -h "$P2" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2);print $2}')
TBLOC2=$("$DUMPE2FS" -h "$P2" 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,"",$2);print $2}')
TAILLE2=$(( ${BLOCS2:-0} * ${TBLOC2:-0} / 1024 ))
[ "$TAILLE2" -gt 10000 ] && [ "$TAILLE2" -lt 200000 ] || err "$P2 (${TAILLE2} Kio) n'a pas la taille de la partition /data d'une Qiara (environ 20 Mio)"
ETIQUETTE2=$("$DUMPE2FS" -h "$P2" 2>/dev/null | awk -F: '/^Filesystem volume name/{gsub(/^ +/,"",$2);print $2}')
ok "carte Qiara reconnue : $P1 systeme, $P2 /data (${TAILLE2} Kio), $P3 /media"

# partitions montees automatiquement par l'ordinateur (Linux) : demontees seulement une fois la carte reconnue,
# et jamais en --essai ; un demontage refuse arrete tout (ecrire sur un systeme de fichiers monte l'abimerait).
MONTEES=""
if [ -z "$IMAGE" ] && command -v findmnt >/dev/null 2>&1; then
  for p in "$P1" "$P2" "$P3"; do findmnt -rno TARGET "$p" >/dev/null 2>&1 && MONTEES="$MONTEES $p"; done
fi
if [ -n "$MONTEES" ]; then
  if [ "$ESSAI" = 1 ]; then info "partitions montees par l'ordinateur :$MONTEES (elles seront demontees hors --essai)"
  else for p in $MONTEES; do umount "$p" 2>/dev/null || err "$p ne se demonte pas (fichier ouvert dans un explorateur ?) : fermer les fenetres de la carte, puis relancer ; rien n'a ete ecrit"; info "$p demontee"; done; fi
fi
P3_MONTEE=0; case " $MONTEES " in *" $P3 "*) P3_MONTEE=1;; esac
if [ "$ESSAI" = 1 ] && [ "$P3_MONTEE" = 1 ]; then info "controle e2fsck de $P3 saute en --essai (partition montee)"
else "$E2FSCK" -n "$P3" >/dev/null 2>&1 || err "$P3 (/media) presente des erreurs : la reparer d'abord ($E2FSCK -f $P3, avec sudo), puis relancer ; rien n'a ete ecrit"; fi

if existe "$P2" /openqiara.json; then
  [ "$REMPLACER" = 1 ] || err "cette carte porte deja OpenQiara (/data/openqiara.json). Pour garder capteurs et reglages, utiliser mettre-a-niveau.sh par SSH ; pour repartir de zero, ajouter --remplacer"
  info "carte deja sous OpenQiara : sa configuration est sauvegardee puis remplacee (--remplacer)"
fi

# ---------------------------------------------------------------- fichiers prepares
F=$TMP/data; mkdir -p "$F"
printf '%s' "$WIFI_SSID" > "$F/wifi_ssid"; printf '%s' "$WIFI_PASS" > "$F/wifi_pass"
: > "$F/bridge"
cp "$PAQUET/boot.sh" "$F/boot.sh"
cp "$PAQUET/openqiarad-claude-v15-compact" "$F/openqiarad"
cp "$CLE" "$F/ssh_authorized_keys"
fichier_openqiara "$F/openqiara.json"
fichier_defauts "$F/openqiara-defauts.json"
{ printf '%s\n' "# /data/post_boot.sh : reglages locaux, execute par boot.sh a la fin du demarrage (sortie dans /data/post_boot.log)."; bloc_post_boot; } > "$F/post_boot.sh"
bash -n "$F/post_boot.sh" || err "post_boot.sh fabrique invalide"
M=$TMP/media; mkdir -p "$M"
for f in openqiarad-claude-v15 openqiarad-claude-v15-compact qp-setup.sh installer.sh services-cloud.sh reglage.sh; do cp "$PAQUET/$f" "$M/$f"; done
for f in openqiarad-claude-v15 openqiarad-claude-v15-compact; do printf '%s  %s\n' "$(sha256_de "$M/$f")" "$f" > "$M/$f.sha256"; done
cp "$F/openqiara-defauts.json" "$M/openqiara-defauts.json"
fichier_installation "$M/installation.conf"
: > "$M/A-INSTALLER"
ok "fichiers prepares"

# place libre sur /media : le dossier oqc, puis les emplacements de QIARA Plus (version complete, copie de secours)
LIBRE3=$("$DUMPE2FS" -h "$P3" 2>/dev/null | awk -F: '/^Free blocks/{gsub(/ /,"",$2);print $2}')
TBLOC3=$("$DUMPE2FS" -h "$P3" 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,"",$2);print $2}')
LIBRE3=$(( ${LIBRE3:-0} * ${TBLOC3:-0} / 1024 ))
BESOIN3=$(( $(du -sk "$M" | cut -f1) + 61440 ))
[ "$LIBRE3" -ge "$BESOIN3" ] || err "$P3 (/media) n'a que $LIBRE3 Kio libres, il en faut $BESOIN3 : faire de la place sur la carte, puis relancer ; rien n'a ete ecrit"
ok "place libre sur /media : $LIBRE3 Kio (il en faut $BESOIN3)"

# appairage radio d'origine (capteurs deja appaires avec la camera) : recopie a l'identique dans le nouveau /data
APPAIRAGE=""
for n in fbxhome.xml fbxhome.xml.0 fbxhome.xml.1 fbxhome.xml.2 fbxhome.xml.3 fbxhome.xml.4 fbxhome.xml.5 fbxhome.xml.6 fbxhome.xml.7 fbxhome.xml.8 fbxhome.xml.9; do
  if existe "$P2" "/$n"; then
    "$DEBUGFS" -R "dump /$n $F/$n" "$P2" >/dev/null 2>&1 && [ -s "$F/$n" ] && APPAIRAGE="$APPAIRAGE $n"
  fi
done
[ -n "$APPAIRAGE" ] && ok "appairage radio d'origine repris :$APPAIRAGE" || info "aucun appairage radio d'origine sur la carte (capteurs a appairer depuis l'interface web)"

# autres fichiers du constructeur, recopies tels quels s'ils existent : licence de la detection interne (iv_license, sans
# laquelle hlcamd perd la detection de personnes), cles et identite (passphrase, video.key, ssl/), reglages d'image de
# l'application Qiara (hlcamd-parameters.json), microgiciels des capteurs (firmwares/). Dossiers recopies a plat (un niveau).
CONSTRUCTEUR=""; DOSSIERS=""
for n in iv_license passphrase video.key hlcamd-parameters.json; do
  if existe "$P2" "/$n"; then "$DEBUGFS" -R "dump /$n $F/$n" "$P2" >/dev/null 2>&1 && [ -e "$F/$n" ] && CONSTRUCTEUR="$CONSTRUCTEUR $n"; fi
done
mkdir -p "$TMP/dossiers"
for d in ssl firmwares; do
  if existe "$P2" "/$d"; then
    "$DEBUGFS" -R "rdump /$d $TMP/dossiers" "$P2" >/dev/null 2>&1
    [ -d "$TMP/dossiers/$d" ] && { DOSSIERS="$DOSSIERS $d"; CONSTRUCTEUR="$CONSTRUCTEUR $d/($(find "$TMP/dossiers/$d" -maxdepth 1 -type f | wc -l | tr -d ' '))"; }
  fi
done
[ -n "$CONSTRUCTEUR" ] && ok "fichiers du constructeur repris :$CONSTRUCTEUR"
TOTAL2=$(du -sk "$F" "$TMP/dossiers" | awk '{t+=$1} END {print t}')
[ "$TOTAL2" -le 12288 ] || err "les fichiers a poser sur /data font $TOTAL2 Kio, plus que les 12 Mio prevus : rien n'a ete ecrit"

if [ "$ESSAI" = 1 ]; then msg "=== essai : tout est pret, rien n'a ete ecrit ==="; exit 0; fi
if [ "$OUI" != 1 ]; then
  printf 'La carte va etre modifiee (/data reformatee). Continuer ? [o/N] '; read -r r
  case "$r" in [oOyY]*) ;; *) msg "abandon, rien n'a ete ecrit"; exit 1;; esac
fi

# ---------------------------------------------------------------- sauvegarde
SAUV="$PWD/sauvegarde-carte-$(date +%Y%m%d-%H%M%S)"
( umask 077; mkdir -p "$SAUV" )   # la sauvegarde contient le Wi-Fi et les cles du constructeur : lisible par son seul proprietaire
dd if="$P2" of="$SAUV/data-p2.img" bs=1048576 2>/dev/null || err "sauvegarde de $P2 impossible : rien n'a ete ecrit"
# debugfs decoupe sa commande aux espaces : le fichier est lu dans $TMP (sans espace), puis copie dans la sauvegarde,
# dont le chemin peut en contenir (dossier « Telechargements\Dossier d'ete (copie) » sous Windows, rejeu WSL du simulateur)
"$DEBUGFS" -R "dump /etc/init.d/rcS.real $TMP/rcS.sauvegarde" "$P1" >/dev/null 2>&1
[ -s "$TMP/rcS.sauvegarde" ] && cp "$TMP/rcS.sauvegarde" "$SAUV/rcS.real" || err "sauvegarde de rcS.real impossible : rien n'a ete ecrit"
chmod 600 "$SAUV"/*
# sous sudo, la sauvegarde revient a l'utilisateur (sans cela, elle appartiendrait a root)
[ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID}" != 0 ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$SAUV" 2>/dev/null || true
ok "sauvegarde : $SAUV (image de /data, rcS.real)"

# ---------------------------------------------------------------- p1 : rcS.real
cp "$SAUV/rcS.real" "$TMP/rcS.real"; change=0
if grep -q 'tune2fs -O \^has_journal' "$TMP/rcS.real"; then
  sed 's|tune2fs -O \^has_journal|tune2fs -O has_journal|g; s|e2fsck -c -y -f /dev/mmcblk0p2|e2fsck -y -f /dev/mmcblk0p2|' "$TMP/rcS.real" > "$TMP/rcS.new" && mv "$TMP/rcS.new" "$TMP/rcS.real"
  change=1; ok "rcS.real : journal ext4 garde sur /data"
fi
if ! grep -q "OpenQiara autostart" "$TMP/rcS.real"; then
  printf '\n\n# === OpenQiara autostart (added by sd_setup) ===\n[ -x /data/boot.sh ] && /data/boot.sh >> /data/boot_debug.log 2>&1 &\n' >> "$TMP/rcS.real"
  change=1; ok "rcS.real : lancement de /data/boot.sh ajoute"
fi
if [ "$change" = 1 ]; then
  # ecrit d'abord a cote (rcS.real.oqc), relu, puis mis en place : la carte n'est jamais sans rcS.real valide
  # plus d'un instant (debugfs n'a pas de renommage : rm de l'ancien puis link du nouveau, dans la meme session)
  D=/etc/init.d
  printf 'rm %s/rcS.real.oqc\nwrite %s %s/rcS.real.oqc\nset_inode_field %s/rcS.real.oqc mode 0100755\nset_inode_field %s/rcS.real.oqc uid 0\nset_inode_field %s/rcS.real.oqc gid 0\n' "$D" "$TMP/rcS.real" "$D" "$D" "$D" "$D" | "$DEBUGFS" -w "$P1" >/dev/null 2>&1
  "$DEBUGFS" -R "dump $D/rcS.real.oqc $TMP/rcS.relu" "$P1" >/dev/null 2>&1
  cmp -s "$TMP/rcS.real" "$TMP/rcS.relu" || err "rcS.real prepare relu different (rien n'est en place ; sauvegarde : $SAUV/rcS.real)"
  printf 'rm %s/rcS.real\nlink %s/rcS.real.oqc %s/rcS.real\nunlink %s/rcS.real.oqc\n' "$D" "$D" "$D" "$D" | "$DEBUGFS" -w "$P1" >/dev/null 2>&1
  "$DEBUGFS" -R "dump $D/rcS.real $TMP/rcS.relu2" "$P1" >/dev/null 2>&1
  cmp -s "$TMP/rcS.real" "$TMP/rcS.relu2" || err "rcS.real relu different de celui ecrit : remettre la sauvegarde ($SAUV/rcS.real) sur $P1:/etc/init.d/rcS.real avec debugfs -w, ou reecrire l'image complete de la carte"
else info "rcS.real deja prepare"; fi

# ---------------------------------------------------------------- p2 : /data
ETQ=(); [ -n "$ETIQUETTE2" ] && [ "$ETIQUETTE2" != "<none>" ] && ETQ=(-L "$ETIQUETTE2")
"$MKE2FS" -q -F -t ext4 -b 4096 -N 256 -m 0 ${ETQ[@]+"${ETQ[@]}"} "$P2" >/dev/null 2>&1 || err "formatage de $P2 impossible (sauvegarde : $SAUV)"
CMDS=""
for f in "$F"/*; do
  n=$(basename "$f")
  CMDS+="write $f $n"$'\n'"set_inode_field $n uid 0"$'\n'"set_inode_field $n gid 0"$'\n'
  case "$n" in openqiarad|boot.sh) CMDS+="set_inode_field $n mode 0100755"$'\n';; wifi_pass|openqiara.json|passphrase|video.key|iv_license) CMDS+="set_inode_field $n mode 0100600"$'\n';; *) CMDS+="set_inode_field $n mode 0100644"$'\n';; esac
done
for d in $DOSSIERS; do
  case "$d" in ssl) md=040700; mf=0100600;; *) md=040755; mf=0100644;; esac
  CMDS+="mkdir $d"$'\n'"set_inode_field $d uid 0"$'\n'"set_inode_field $d gid 0"$'\n'"set_inode_field $d mode $md"$'\n'
  for f in "$TMP/dossiers/$d"/*; do [ -f "$f" ] || continue; n=$d/$(basename "$f"); CMDS+="write $f $n"$'\n'"set_inode_field $n uid 0"$'\n'"set_inode_field $n gid 0"$'\n'"set_inode_field $n mode $mf"$'\n'; done
done
printf '%s' "$CMDS" | "$DEBUGFS" -w "$P2" >/dev/null 2>&1
ok "/data reformatee et remplie ($(ls "$F" | wc -l | tr -d ' ') fichiers${DOSSIERS:+, dossiers :$DOSSIERS})"

# ---------------------------------------------------------------- p3 : /media/oqc
CMDS="mkdir oqc"$'\n'"cd /oqc"$'\n'
for f in "$M"/*; do n=$(basename "$f"); CMDS+="rm $n"$'\n'; done
for f in "$M"/*; do
  n=$(basename "$f")
  CMDS+="write $f $n"$'\n'"set_inode_field $n uid 0"$'\n'"set_inode_field $n gid 0"$'\n'
  case "$n" in openqiarad-claude-v15|openqiarad-claude-v15-compact|*.sh) CMDS+="set_inode_field $n mode 0100755"$'\n';; *) CMDS+="set_inode_field $n mode 0100644"$'\n';; esac
done
printf '%s' "$CMDS" | "$DEBUGFS" -w "$P3" >/dev/null 2>&1
ok "/media/oqc rempli ($(ls "$M" | wc -l | tr -d ' ') fichiers)"

# ---------------------------------------------------------------- verification par relecture
mkdir -p "$TMP/relu/data" "$TMP/relu/media"
for f in "$F"/*; do n=$(basename "$f"); "$DEBUGFS" -R "dump /$n $TMP/relu/data/$n" "$P2" >/dev/null 2>&1; cmp -s "$f" "$TMP/relu/data/$n" || err "/data/$n relu different de celui ecrit"; done
for d in $DOSSIERS; do for f in "$TMP/dossiers/$d"/*; do [ -f "$f" ] || continue; n=$(basename "$f"); "$DEBUGFS" -R "dump /$d/$n $TMP/relu/data/$d-$n" "$P2" >/dev/null 2>&1; cmp -s "$f" "$TMP/relu/data/$d-$n" || err "/data/$d/$n relu different de celui ecrit"; done; done
for f in "$M"/*; do n=$(basename "$f"); "$DEBUGFS" -R "dump /oqc/$n $TMP/relu/media/$n" "$P3" >/dev/null 2>&1; cmp -s "$f" "$TMP/relu/media/$n" || err "/media/oqc/$n relu different de celui ecrit"; done
[ "$change" = 1 ] && { "$E2FSCK" -fn "$P1" >/dev/null 2>&1 || err "systeme (p1) : controle e2fsck en echec apres ecriture de rcS.real (sauvegarde : $SAUV/rcS.real)"; }
"$E2FSCK" -fn "$P2" >/dev/null 2>&1 || err "/data : controle e2fsck en echec apres ecriture"
"$E2FSCK" -fn "$P3" >/dev/null 2>&1 || err "/media : controle e2fsck en echec apres ecriture"
ok "relecture : tous les fichiers identiques, systemes de fichiers sains"
sync

msg ""
msg "=== carte prete ==="
msg "1. Ejecter la carte, la remettre dans la camera, brancher la camera."
msg "2. Premier demarrage : environ 2 min ; l'installation se termine seule (QIARA Plus, version complete, services du cloud),"
msg "   puis la camera redemarre une fois (10 a 15 min en tout). Rapport : /media/oqc/rapport.txt (sh /media/oqc/installer.sh etat)."
msg "3. Trouver la camera sur le reseau (box, ou : arp -a), ouvrir http://<adresse de la camera> et choisir le mot de passe admin."
msg "4. Dans Home Assistant : les entites arrivent seules par MQTT ; copier le paquet home-assistant/ (voir LISEZ-MOI)."
