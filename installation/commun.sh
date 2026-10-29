# commun.sh : fonctions partagees par preparer-carte-sd.sh et mettre-a-niveau.sh (bash, Linux, macOS ou WSL).
# Lecture du fichier de configuration (lu, jamais execute) et fabrication des fichiers poses sur la camera.

msg()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '  info  %s\n' "$*"; }
err()  { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

# cfg_charger fichier : lit les lignes NOM=valeur dans des variables CFG_NOM (guillemets et fins de ligne Windows retires).
cfg_charger() {
  [ -f "$1" ] || err "fichier de configuration introuvable : $1"
  local ligne nom val
  while IFS= read -r ligne || [ -n "$ligne" ]; do
    ligne=${ligne%$'\r'}
    ligne=${ligne#$'\xEF\xBB\xBF'}   # marque d'ordre des octets d'un fichier enregistre par le Bloc-notes
    case "$ligne" in ''|'#'*) continue;; esac
    case "$ligne" in *=*) ;; *) continue;; esac
    nom=${ligne%%=*}; val=${ligne#*=}
    nom=$(printf '%s' "$nom" | tr -d ' \t')
    case "$nom" in *[!A-Z0-9_]*|'') continue;; esac
    case "$val" in \"*\") val=${val#\"}; val=${val%\"};; esac
    printf -v "CFG_$nom" '%s' "$val"
  done < "$1"
}
cfg() { local v="CFG_$1"; printf '%s' "${!v:-$2}"; }

# entier_normal nom valeur : chiffres seulement, puis forme decimale sans zeros de tete (« 0022 » devient 22 ;
# un zero de tete donnerait un JSON invalide ou un nombre lu en octal par le shell de la camera).
entier_normal() { case "$2" in ''|*[!0-9]*) err "$1 doit etre un nombre entier (lu : $2)";; esac; printf '%s' "$((10#$2))"; }

# dossier_utilisateur : dossier personnel de l'utilisateur qui a lance l'outil, meme sous sudo (qui remet HOME a /root
# sous Ubuntu, Debian et Fedora : « ~ » designerait alors les cles de root, pas celles de l'utilisateur).
dossier_utilisateur() {
  local d=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    if command -v getent >/dev/null 2>&1; then d=$(getent passwd "$SUDO_USER" | cut -d: -f6); fi
    [ -n "$d" ] || d=$(eval "printf '%s' ~$(printf '%q' "$SUDO_USER")" 2>/dev/null) || d=""
    case "$d" in /*) ;; *) d="";; esac
  fi
  printf '%s' "${d:-$HOME}"
}

# cfg_verifier mode : controle les valeurs (mode = carte ou ssh) et pose les variables normalisees.
cfg_verifier() {
  CODEC=$(cfg CODEC h265); DETECTION=$(cfg DETECTION_INTERNE oui); REGLAGES=$(cfg REGLAGES_IMAGE deverrouilles)
  QIARA_PLUS=$(cfg QIARA_PLUS oui); SERVICES_CLOUD=$(cfg SERVICES_CLOUD neutraliser); HOMEKIT=$(cfg HOMEKIT non)
  DEBIT=$(entier_normal DEBIT "$(cfg DEBIT 2500000)") || exit 1
  IMAGE_CLE=$(entier_normal IMAGE_CLE "$(cfg IMAGE_CLE 1)") || exit 1
  SSH_SECOURS=$(entier_normal SSH_SECOURS_PORT "$(cfg SSH_SECOURS_PORT 0)") || exit 1
  case "$CODEC" in h264|h265) ;; *) err "CODEC doit valoir h264 ou h265 (lu : $CODEC)";; esac
  [ "$DEBIT" -ge 500000 ] && [ "$DEBIT" -le 8000000 ] || err "DEBIT : de 500000 a 8000000 (lu : $DEBIT)"
  # IMAGE_CLE = option --gop-denum de hlcamd : groupe de 30/N images, une image cle toutes les 1/N s (1 -> 1 s, 2 -> 0,5 s, mesure)
  [ "$IMAGE_CLE" -ge 1 ] && [ "$IMAGE_CLE" -le 2 ] || err "IMAGE_CLE : 1 (une image cle par seconde) ou 2 (toutes les 0,5 s) (lu : $IMAGE_CLE)"
  case "$DETECTION" in oui|non) ;; *) err "DETECTION_INTERNE : oui ou non";; esac
  case "$REGLAGES" in deverrouilles|verrouilles) ;; *) err "REGLAGES_IMAGE : deverrouilles ou verrouilles";; esac
  case "$QIARA_PLUS" in oui|non) ;; *) err "QIARA_PLUS : oui ou non";; esac
  case "$SERVICES_CLOUD" in neutraliser|laisser) ;; *) err "SERVICES_CLOUD : neutraliser ou laisser";; esac
  # ports deja pris sur la camera : 22 (SSH), 53 (dnsmasq), 80 (interface web), 5353 (mDNS), 8554 (RTSP)
  [ "$SSH_SECOURS" -le 65535 ] || err "SSH_SECOURS_PORT : 0, ou un port de 1024 a 65535 (lu : $SSH_SECOURS)"
  case "$SSH_SECOURS" in 0) ;; 22|53|80|5353|8554) err "SSH_SECOURS_PORT : le port $SSH_SECOURS est deja utilise sur la camera (prendre par exemple 2222)";;
    *) [ "$SSH_SECOURS" -ge 1024 ] || err "SSH_SECOURS_PORT : 0, ou un port de 1024 a 65535 (lu : $SSH_SECOURS)";; esac
  case "$HOMEKIT" in oui|non) ;; *) err "HOMEKIT : oui ou non";; esac
  [ "$HOMEKIT" = oui ] && [ "$CODEC" = h265 ] && err "HOMEKIT=oui exige CODEC=h264 (Apple Maison ne lit pas le H.265)"
  CLE=$(cfg CLE_SSH_PUBLIQUE "")
  case "$CLE" in "~"|"~/"*) CLE="$(dossier_utilisateur)${CLE#\~}";; esac
  if [ "$1" = carte ]; then
    WIFI_SSID=$(cfg WIFI_SSID ""); WIFI_PASS=$(cfg WIFI_MOT_DE_PASSE "")
    [ -n "$WIFI_SSID" ] || err "WIFI_SSID est vide"
    [ -n "$WIFI_PASS" ] || err "WIFI_MOT_DE_PASSE est vide"
    [ ${#WIFI_PASS} -ge 8 ] && [ ${#WIFI_PASS} -le 64 ] || err "WIFI_MOT_DE_PASSE : un mot de passe WPA2 fait de 8 a 64 caracteres (lu : ${#WIFI_PASS})"
    [ -n "$CLE" ] || err "CLE_SSH_PUBLIQUE est vide : sans cle, personne ne pourra se connecter a la camera"
    MQTT_SERVEUR=$(cfg MQTT_SERVEUR ""); MQTT_PORT=$(entier_normal MQTT_PORT "$(cfg MQTT_PORT 1883)") || exit 1
    [ -n "$MQTT_SERVEUR" ] || err "MQTT_SERVEUR est vide"
    # adresse seule (192.168.1.10, homeassistant.local), ou precedee d'un schema : ssl://, tls://, mqtts:// pour une
    # liaison chiffree (OpenQiara les accepte), tcp:// ou mqtt:// sans chiffrement. Le port va dans MQTT_PORT.
    MQTT_SCHEMA=tcp
    case "$MQTT_SERVEUR" in
      *://*) MQTT_SCHEMA=${MQTT_SERVEUR%%://*}; MQTT_SERVEUR=${MQTT_SERVEUR#*://}
             case "$MQTT_SCHEMA" in tcp|mqtt|ssl|tls|mqtts) ;; *) err "MQTT_SERVEUR : schema « $MQTT_SCHEMA:// » inconnu (tcp, mqtt, ssl, tls ou mqtts)";; esac;;
    esac
    case "$MQTT_SERVEUR" in
      ''|*[[:space:]/]*|*:*) err "MQTT_SERVEUR : l'adresse seule, sans espace, sans « / » et sans « :port » (le port va dans MQTT_PORT ; exemple : 192.168.1.10)";;
    esac
    [ "$MQTT_PORT" -ge 1 ] && [ "$MQTT_PORT" -le 65535 ] || err "MQTT_PORT : de 1 a 65535 (lu : $MQTT_PORT)"
  fi
  if [ -n "$CLE" ]; then
    [ -f "$CLE" ] || err "cle publique introuvable : $CLE (creer une cle : ssh-keygen -t ed25519)"
    case "$(head -c 40 "$CLE")" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;; *) err "$CLE n'est pas une cle publique SSH (prendre le fichier .pub)";; esac
  fi
}

# json_chaine valeur : chaine JSON echappee (guillemets compris).
json_chaine() {
  local s=$1 o='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      '"') o+='\"';; '\') o+='\\';;
      $'\n') o+='\n';; $'\r') o+='\r';; $'\t') o+='\t';;
      *) if [[ "$c" < ' ' ]]; then o+=$(printf '\\u%04x' "'$c"); else o+=$c; fi;;
    esac
  done
  printf '"%s"' "$o"
}

# fichier_defauts sortie : reglages par defaut, fusionnes par OpenQiara a son demarrage la ou sa configuration ne dit rien.
fichier_defauts() {
  local iv=true lock=false
  [ "$DETECTION" = non ] && iv=false
  [ "$REGLAGES" = verrouilles ] && lock=true
  # pas de « rtsp_enabled » ici : un choix deja fait sur la camera (RTSP coupe) doit rester tel quel
  printf '{"video":{"codec":"%s","bitrate":%s,"gop_denum":%s,"iv_detection":%s,"lock":%s}}\n' \
    "$CODEC" "$DEBIT" "$IMAGE_CLE" "$iv" "$lock" > "$1"
}

# fichier_openqiara sortie : configuration initiale d'OpenQiara (carte SD neuve seulement).
fichier_openqiara() {
  local hk=false user pass pref
  [ "$HOMEKIT" = oui ] && hk=true
  user=$(json_chaine "$(cfg MQTT_UTILISATEUR "")"); pass=$(json_chaine "$(cfg MQTT_MOT_DE_PASSE "")")
  pref=$(json_chaine "$(cfg MQTT_PREFIXE openqiara)")
  cat > "$1" <<EOF
{
  "mqtt": {
    "broker": $(json_chaine "$MQTT_SCHEMA://$MQTT_SERVEUR:$MQTT_PORT"),
    "username": $user,
    "password": $pass,
    "topic_prefix": $pref
  },
  "homekit": {
    "enabled": $hk
  },
  "rtsp": {
    "enabled": true
  },
  "admin": {}
}
EOF
}

# fichier_installation sortie : choix lus par installer.sh sur la camera.
fichier_installation() {
  printf '%s\n' "# Choix de l'installation (fabrique par l'outil d'installation, lu par installer.sh)" \
    "QIARA_PLUS=$QIARA_PLUS" "SERVICES_CLOUD=$SERVICES_CLOUD" "SSH_SECOURS_PORT=$SSH_SECOURS" > "$1"
}

# BLOC_POST_BOOT : bloc ajoute a /data/post_boot.sh, qui lance installer.sh tant qu'une etape reste a faire.
BLOC_DEBUT='# >>> openqiara-claude-v15 (ne pas modifier ce bloc) >>>'
BLOC_FIN='# <<< openqiara-claude-v15 <<<'
bloc_post_boot() {
  printf '%s\n%s\n%s\n' "$BLOC_DEBUT" \
    '[ -f /media/oqc/installer.sh ] && { [ -e /media/oqc/A-INSTALLER ] || [ -e /media/oqc/A-VERIFIER ]; } && ( nohup sh /media/oqc/installer.sh auto >/dev/null 2>&1 & )' \
    "$BLOC_FIN"
}

# paquet_verifier dossier : les fichiers de la camera sont presents et conformes a SHA256SUMS.
PAQUET_FICHIERS="openqiarad-claude-v15 openqiarad-claude-v15-compact boot.sh qp-setup.sh installer.sh services-cloud.sh reglage.sh"
paquet_verifier() {
  local d=$1 f w n
  [ -f "$d/SHA256SUMS" ] || err "paquet incomplet : $d/SHA256SUMS absent"
  for f in $PAQUET_FICHIERS; do
    [ -s "$d/$f" ] || err "paquet incomplet : $d/$f absent"
    w=$(awk -v n="$f" '$2==n || $2=="*"n {print $1}' "$d/SHA256SUMS")
    [ -n "$w" ] || err "$f absent de SHA256SUMS"
    [ "$(sha256_de "$d/$f")" = "$w" ] || err "empreinte de $f non conforme : paquet abime, le telecharger de nouveau"
  done
  ok "paquet conforme ($(echo $PAQUET_FICHIERS | wc -w | tr -d ' ') fichiers, empreintes verifiees)"
}
sha256_de() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
