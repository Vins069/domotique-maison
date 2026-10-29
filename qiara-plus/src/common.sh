# common.sh - fonctions communes de « Qiara Plus » (Claude, 26/10/2026, v2 : econome en memoire et en processus ;
# v6 27/10/2026 : ages mesures sur l'uptime et le numero de demarrage, jamais sur la seule horloge murale)
# Shell : busybox ash de la camera. Rien ici ne doit supposer bash.
# Les durees se mesurent sur /proc/uptime (monotone) : l'horloge murale demarre en 1970 et saute au reglage NTP.
QP=${QP:-/data/qp}                 # petit : etat, binaire d'origine (carte /data, 20 Mio)
BULK=${QP_BULK:-/media/qp}         # gros : emplacements good et new (carte /media, 2,8 Go)
RUN=${QP_RUN:-/tmp/qp}             # memoire vive : sante, ordres, etat des essais
ST=$QP/state
LOG=${QP_LOG:-/data/openqiarad.log}
OLD=${QP_OLD:-/media/openqiarad.old}   # repli ultime du lanceur (et de post_boot.sh si /data/openqiarad disparait) ; v6 : rafraichi par promote/seed-good, empreinte a cote
[ -d "$ST" ] && [ -d "$RUN" ] || mkdir -p "$ST" "$RUN" 2>/dev/null

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
now() { date +%s; }
log() { echo "[${QP_WHO:-qp}] $(ts) $*" >> "$LOG" 2>/dev/null; }
# lecture d'une ligne sans processus supplementaire : rd VAR fichier [defaut]
rd() { eval "$1=" ; [ -s "$2" ] && { read -r "$1" < "$2" || :; }; eval "[ -n \"\$$1\" ] || $1=\${3-}"; }
up_now() { _upt=0; read -r _upt _upr < "${QP_UPTIME:-/proc/uptime}" 2>/dev/null; UP=${_upt%%.*}; case "$UP" in ''|*[!0-9]*) UP=0;; esac; }   # met a jour $UP (secondes depuis le demarrage ; QP_UPTIME : banc d'essai)
boot_id() { if [ -n "$QP_BOOT_ID" ]; then BOOT=$QP_BOOT_ID; else read -r BOOT < /proc/sys/kernel/random/boot_id; fi; }
# v6 : numero de demarrage. $ST/boot_seq = "boot_id numero" ; le lanceur l'incremente a chaque nouveau demarrage (boot_seq_bump),
# les autres le lisent (boot_seq_now pose SEQ, en comptant 1 de plus si le fichier vient d'un autre demarrage). Il permet de
# faire expirer, apres un nombre de demarrages, ce qui a ete date a l'horloge de 1970 (sans reseau, l'heure n'est pas fiable).
boot_seq_now() { boot_id; _sb=; _ss=0; [ -s "$ST/boot_seq" ] && read -r _sb _ss < "$ST/boot_seq" 2>/dev/null; toint _ss 0; SEQ=$_ss; [ "$_sb" = "$BOOT" ] || SEQ=$((_ss + 1)); }
boot_seq_bump() { boot_seq_now; [ "$_sb" = "$BOOT" ] || put "$ST/boot_seq" "$BOOT $SEQ"; }
# Entiers surs pour $(( )) : en mode POSIX, une erreur arithmetique ("12x", ou "08" lu en octal) ARRETE le shell.
# Seuls les chiffres sont acceptes ; les zeros de tete sont retires.
int() { case "$1" in ''|*[!0-9]*) echo "${2:-0}";; *) _i=${1#"${1%%[!0]*}"}; echo "${_i:-0}";; esac; }
toint() { eval "case \"\$$1\" in ''|*[!0-9]*) $1=\${2:-0};; *) $1=\${$1#\"\${$1%%[!0]*}\"}; $1=\${$1:-0};; esac"; }    # toint VAR [defaut] : sans processus

# Ecriture atomique : fichier temporaire du meme dossier, puis renommage.
put() { echo "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null; }
get() { if [ -s "$1" ]; then head -n1 "$1"; else echo "$2"; fi; }
# Resultat de la derniere mise a jour : en memoire vive (lu par les anciennes versions d'OpenQiara) ET sur la carte
# (il survit a un redemarrage). Ecrit seulement lors d'une mise a jour ou d'un retour : usure negligeable.
result() { put "$RUN/last_update_result" "$1"; put "$ST/last_update_result" "$1"; }
last_result() { rd _lr "$RUN/last_update_result" ""; [ -n "$_lr" ] || rd _lr "$ST/last_update_result" aucun; }
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
# v5 : l'application lancee par le lanceur. live_child pose CH a son numero de processus, seulement si ce numero vit ET porte le
# nom de l'application (openqiarad, ou openqiarad.old en repli ultime) : $ST/child est sur la carte, il survit a un redemarrage,
# et le numero peut avoir ete repris par un autre programme (dropbear, hlcamd...) qu'un arret ne doit jamais toucher.
APP_COMM=${QP_APP_COMM:-openqiarad}
live_child() {
  rd CH "$ST/child" 0; toint CH 0
  [ "$CH" != 0 ] && kill -0 "$CH" 2>/dev/null || { CH=0; return 1; }
  _c=; read -r _c < /proc/$CH/comm 2>/dev/null
  case "$_c" in "$APP_COMM"|"$APP_COMM".*) return 0;; esac
  CH=0; return 1
}

# Dossier d'un emplacement : factory sur /data (toujours present), good et new sur /media.
sd() { case "$1" in factory) echo "$QP/slots/factory";; *) echo "$BULK/slots/$1";; esac; }
# Ordre de repli : new -> good -> prev (la version validee avant good) -> factory (origine, sur /data)
order() { case "$1" in new) echo "new good prev factory";; good) echo "good prev factory";; prev) echo "prev factory";; *) echo "factory";; esac; }

# Age d'un evenement date "boot_id uptime horloge" : age_of B U W pose AGE (secondes), mesure sur l'uptime si meme demarrage,
# sur l'horloge murale sinon et seulement si elle est plausible des deux cotes (apres 2023-11, croissante) ; AGE=-1 si inconnu
# (autre demarrage, horloge de 1970 d'un cote). Un W seul (ancien format, numerique) vaut "autre demarrage".
age_of() {
  _ab=$1; _au=$2; _aw=$3; AGE=-1
  boot_id; up_now
  if [ -n "$_ab" ] && [ "$_ab" = "$BOOT" ]; then AGE=$(( UP - $(int "$_au" 0) )); [ "$AGE" -lt 0 ] && AGE=0; return 0; fi
  _an=$(now); _aw=$(int "$_aw" 0)
  if [ "$_an" -gt 1700000000 ] && [ "$_aw" -gt 1700000000 ] && [ "$_an" -ge "$_aw" ]; then AGE=$((_an - _aw)); fi
}
# Marquage BAD : "boot_id uptime horloge numero_de_demarrage". Il expire apres QP_BAD_TTL s (mesure sur uptime si meme
# demarrage, sur l'horloge sinon et seulement si elle est plausible) ou, quand l'age est inconnu (pose a l'horloge de 1970,
# puis redemarrage), apres QP_BAD_BOOTS demarrages (v6 : sans cela un emplacement ecarte avant le reglage de l'heure l'etait
# pour toujours). En cas de doute, l'emplacement reste ecarte.
BAD_TTL=${QP_BAD_TTL:-1800}
BAD_BOOTS=${QP_BAD_BOOTS:-2}
slot_bad() {
  _f=$(sd "$1")/BAD
  [ -e "$_f" ] || return 1
  [ "$1" = factory ] && return 1       # le binaire d'origine n'est jamais ecarte
  _b=; _u=; _w=; _q=; read -r _b _u _w _q < "$_f" 2>/dev/null
  [ -z "$_u" ] && [ -z "$_w" ] && { _w=$_b; _b=; }        # ancien format : une seule date
  # v6 : un marquage vide ou illisible (fichier tronque) ne vaut rien : il est retire. Une boucle d'arrets le reposerait
  # correctement en quelques secondes ; le garder aurait ecarte l'emplacement pour toujours.
  case "${_u:-0}${_w:-0}" in *[!0-9]*) rm -f "$_f"; log "marquage BAD de $1 illisible : retire"; return 1;; esac
  [ -n "$_u$_w" ] || { rm -f "$_f"; log "marquage BAD de $1 vide : retire"; return 1; }
  age_of "$_b" "$_u" "$_w"
  if [ "$AGE" -lt 0 ]; then
    _age=0
    case "$_q" in ''|*[!0-9]*) ;; *) boot_seq_now; [ $((SEQ - $(int "$_q" 0))) -ge "$BAD_BOOTS" ] && _age=$BAD_TTL;; esac
  else _age=$AGE; fi
  [ "$_age" -lt "$BAD_TTL" ] && return 0
  rm -f "$_f"; return 1
}
# Emplacement utilisable : binaire non vide, non BAD, empreinte conforme (exigee pour good et new). Pose $VSHA.
slot_valid() {
  _d=$(sd "$1"); VSHA=
  [ -s "$_d/openqiarad" ] || return 1
  slot_bad "$1" && return 1
  if [ -s "$_d/openqiarad.sha256" ]; then
    _want=; read -r _want _x < "$_d/openqiarad.sha256"
    VSHA=$(sha_of "$_d/openqiarad")
    [ "$_want" = "$VSHA" ] || return 1
  else
    [ "$1" = factory ] || return 1
  fi
  return 0
}
mark_bad() { [ "$1" = factory ] && return 0; boot_seq_now; up_now; put "$(sd "$1")/BAD" "$BOOT $UP $(now) $SEQ"; log "emplacement $1 marque BAD"; }
