#!/bin/sh
# qp-guard : surveillant de la camera, lance par post_boot.sh (Claude, 26/10/2026 ; v10 28/10 : le bouton « Redemarrer la camera »
# de Home Assistant n'est plus limite (ORDER_REBOOT_MAX=0 = sans limite, par defaut) ; le budget des redemarrages automatiques reste ; v9 28/10 : aucune commande externe ne peut
# figer la boucle (fbxupstartctl, fbxbusctl, sync, dropbear lances avec un delai maximal : bounded), ordre ssh-restart verifie
# (attente de l'arret de l'ancien dropbear 2222, controle de l'ecoute, journal explicite) ; v8 27/10 : dropbear 2222 relance avec
# maintien de connexion (-K 30), ordre ssh-restart de Home Assistant (relance des deux dropbear, 6 par heure au plus), codec video
# demande a hlcamd (--use-h264/--use-h265) dans le relevé ; v7 27/10 (v6 de la session B + regle video) : hlcamd absent depuis VIDEO_GONE_SEC -> redemarrage
# borne par le budget existant (correction du chien de garde du microcontroleur, OpenQiara ne le comptant plus dans sa sante) ; v6 27/10 : limites horaires sur l'uptime et non
# l'horloge murale, valeurs invalides de guard.conf ramenees au defaut, instantanes de 1970 elagues, use-prev limite ;
# v5 27/10 : guard.conf lu et non execute, arrets verifies, ordres limites ; v4 : instantanes d'incident ; v3 : boite noire, echantillons IV).
# Il observe et, seulement si necessaire, agit dans l'ordre le plus doux :
#  1. application : vivante (sinon lancee au bout de DEAD_SEC), pas figee (fichier de sante), memoire disponible ;
#  2. essai de mise a jour : validation ou retour arriere ;
#  3. SSH 22 et 2222 a l'ecoute ; place sur /data ;
#  4. reseau : passerelle injoignable -> reassociation Wi-Fi -> rechargement du pilote -> redemarrage (limite) ;
#  5. ordres de Home Assistant (fichiers deposes par l'application dans $RUN/cmd/) ;
#  6. diagnostic : reglages video effectifs de hlcamd, etat ecrit dans $RUN/guard-status ;
#  7. (v7) video : hlcamd absent depuis VIDEO_GONE_SEC -> redemarrage de la camera (budget REBOOT_MAX sur REBOOT_WINDOW).
# Economie : une seule boucle shell ; lectures par builtins (read, case) ; les controles couteux sont espaces.
# Toutes les durees sont mesurees sur /proc/uptime. Chaque action est journalisee avec sa raison.
# Reseau (v8, enquete du 27/10/2026) : la puce Wi-Fi SSV6020 repond elle-meme aux pings et a l'ARP (TTL 255), meme quand le
# Linux de la camera ne repond plus. Le surveillant ne deduit donc JAMAIS l'etat du reseau d'un ping recu de l'exterieur ni d'un
# compteur ICMP : seuls ses propres pings sortants vers la passerelle (net_ok) font foi, comme depuis la v1.
# Shell : /bin/sh de la camera est bash 5.2 (lien sh -> bash) ; BusyBox 1.36 fournit ash. Rien ici ne doit supposer l'un ou l'autre.
QP_WHO=qp-guard
QP=${QP:-/data/qp}
#@INCLUDE common.sh
CONF=$QP/guard.conf
# --- reglages par defaut (modifiables dans guard.conf, lignes NOM=valeur) ---
TICK=10                 # periode de la boucle (s)
SLOW_SEC=60             # controles espaces : SSH, place disque, reglages video, etat
HEALTH_GRACE=300        # delai apres le lancement avant de juger la sante (s)
HEALTH_STALE=180        # sante plus vieille que cela = application figee (s)
PROMOTE_AFTER=180       # fonctionnement sain avant de valider un essai (s)
TRIAL_HANG_MAX=2        # blocages pendant un essai avant retour arriere
MEM_MIN_KB=9000         # MemAvailable sous ce seuil...
MEM_LOW_SEC=300         # ...pendant cette duree = relance de l'application (2 fois par heure au plus)
NET_CHECK_SEC=30        # ping de la passerelle (toutes les TICK s quand elle ne repond plus)
NET_L1_SEC=90           # passerelle muette depuis : reassociation Wi-Fi
NET_L2_SEC=300          #                            rechargement du pilote Wi-Fi
NET_L3_SEC=900          #                            redemarrage de la camera
INCIDENT_MIN_SEC=60     # (v4) coupure au moins aussi longue : instantane d'incident a son retour
MQTT_RESTART_SEC=900    # MQTT coupe alors que le serveur MQTT repond : relance de l'application (2 fois par heure au plus)
HANG_MAX_HOUR=3         # arrets pour blocage hors essai : au plus 3 par heure (au-dela : journalise seulement)
DEAD_SEC=120            # application absente depuis : le surveillant la lance lui-meme
REBOOT_MAX=3            # redemarrages automatiques au plus...
REBOOT_WINDOW=21600     # ...sur cette duree (s)
ORDER_REBOOT_MAX=0      # (v6) redemarrages sur ordre de Home Assistant, budget separe, sur la meme duree ; v10 : 0 = sans limite (defaut)
VIDEO_GONE_SEC=600      # (v7) hlcamd absent depuis : redemarrage de la camera (budget REBOOT_MAX) ; 0 = jamais
SSH_SECOURS_PORT=0      # second SSH de secours lance par le surveillant (dropbear sur ce port, cle seulement) ; 0 = aucun
ENABLE_WIFI_ACTIONS=1
ENABLE_REBOOT=1
# (v7) pas de chien de garde materiel du processeur ici : le microcontroleur radio en a deja un, nourri par OpenQiara
# tant qu'il est sain ; ENABLE_SOC_WDT d'un ancien guard.conf est ignore.
PASSIVE=0               # 1 = observe et journalise seulement, aucune action (essais a blanc sur la camera)
GATEWAY=
DROPBEAR=${QP_DROPBEAR:-/usr/sbin/dropbear}
SYSRQ=${QP_SYSRQ:-/proc/sysrq-trigger}
LAUNCHER=${QP_LAUNCHER:-/data/openqiarad}
NET_TCP=${QP_NET_TCP:-/proc/net/tcp}
# v5 : guard.conf est LU ligne a ligne (NOM=valeur), jamais execute : une ligne abimee par la carte SD ne doit pas arreter le
# surveillant au demarrage (une erreur de syntaxe dans un fichier « source » termine un shell non interactif), et le fichier
# ne doit pas pouvoir lancer de commande. Seuls les noms ci-dessous sont acceptes, avec des valeurs simples.
NUMS="TICK SLOW_SEC HEALTH_GRACE HEALTH_STALE PROMOTE_AFTER TRIAL_HANG_MAX MEM_MIN_KB MEM_LOW_SEC NET_CHECK_SEC NET_L1_SEC NET_L2_SEC NET_L3_SEC INCIDENT_MIN_SEC MQTT_RESTART_SEC HANG_MAX_HOUR DEAD_SEC REBOOT_MAX REBOOT_WINDOW ORDER_REBOOT_MAX VIDEO_GONE_SEC SSH_SECOURS_PORT"
for v in $NUMS; do eval "D_$v=\$$v"; done      # v6 : defauts conserves, repris quand la valeur du fichier n'est pas un entier
if [ -f "$CONF" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|'#'*) continue;; esac
    _v=${_v#\"}; _v=${_v%\"}; _v=${_v#\'}; _v=${_v%\'}
    case "$_v" in *[!A-Za-z0-9._:-]*) log "guard.conf : valeur refusee pour $(echo "$_k" | cut -c1-30)"; continue;; esac
    case "$_k" in
      TICK|SLOW_SEC|HEALTH_GRACE|HEALTH_STALE|PROMOTE_AFTER|TRIAL_HANG_MAX|MEM_MIN_KB|MEM_LOW_SEC|NET_CHECK_SEC|NET_L1_SEC|NET_L2_SEC|NET_L3_SEC|INCIDENT_MIN_SEC|MQTT_RESTART_SEC|HANG_MAX_HOUR|DEAD_SEC|REBOOT_MAX|REBOOT_WINDOW|ORDER_REBOOT_MAX|VIDEO_GONE_SEC|SSH_SECOURS_PORT|ENABLE_WIFI_ACTIONS|ENABLE_REBOOT|PASSIVE|GATEWAY)
        eval "$_k=\$_v" ;;
      ENABLE_SOC_WDT) ;;
      *) log "guard.conf : ligne ignoree ($(echo "$_k" | cut -c1-30))" ;;
    esac
  done < "$CONF"
fi
# v6 : une valeur non numerique (fichier abime, faute de frappe) valait 1 : REBOOT_WINDOW=1 levait le plafond des redemarrages,
# HEALTH_STALE=1 arretait l'application sans cesse. Elle reprend maintenant le defaut, et la ligne est journalisee.
for v in $NUMS; do
  eval "_cur=\$$v; _def=\$D_$v"
  case "$_cur" in
    ''|*[!0-9]*) log "guard.conf : $v=$(echo "$_cur" | cut -c1-20) invalide, defaut $_def conserve"; eval "$v=\$_def" ;;
    *) eval "$v=\$(int \"\$_cur\" \"\$_def\")" ;;
  esac
done
[ "$TICK" -ge 1 ] || TICK=1
[ "$SSH_SECOURS_PORT" -le 65535 ] || { log "guard.conf : SSH_SECOURS_PORT=$SSH_SECOURS_PORT invalide, aucun SSH de secours"; SSH_SECOURS_PORT=0; }
# GATEWAY : adresse IPv4 en chiffres et points, sinon ignoree (une valeur fausse rendrait la passerelle « muette » a jamais :
# reassociation, rechargement du pilote puis redemarrages, 3 par 6 h, sans fin)
case "$GATEWAY" in
  '') ;;
  *[!0-9.]*|.*|*.|*..*) log "guard.conf : GATEWAY=$(echo "$GATEWAY" | cut -c1-20) invalide, passerelle lue dans la table de routage"; GATEWAY= ;;
  *) _o=0; _ifs=$IFS; IFS=.; for _p in $GATEWAY; do _o=$((_o + 1)); [ "$(int "$_p" 999)" -le 255 ] || _o=99; done; IFS=$_ifs
     [ "$_o" = 4 ] || { log "guard.conf : GATEWAY=$GATEWAY invalide, passerelle lue dans la table de routage"; GATEWAY=; } ;;
esac
HEALTH=$RUN/health
CMD=$RUN/cmd
STATUS=$RUN/guard-status
mkdir -p "$CMD" 2>/dev/null

# Un seul surveillant a la fois
GL=$RUN/guard.lock
if ! mkdir "$GL" 2>/dev/null; then
  rd op "$GL/pid" 0
  [ "$op" = 0 ] && { sleep 1; rd op "$GL/pid" 0; }      # v5 : verrou en cours de creation (pid pas encore ecrit) : ne pas le voler
  if [ "$op" != 0 ] && kill -0 "$op" 2>/dev/null; then exit 0; fi
  rm -rf "$GL"; mkdir "$GL" 2>/dev/null || exit 1
fi
echo $$ > "$GL/pid"
trap 'rm -rf "$GL"' EXIT
trap 'exit 0' TERM INT HUP

# --- lectures sans processus ---
health_read() { # pose H_ts H_up H_mqtt H_broker H_ok ; retour 1 si pas de fichier
  H_ts=0; H_up=0; H_mqtt=; H_broker=; H_ok=
  [ -s "$HEALTH" ] || return 1
  while IFS='=' read -r k v; do
    case "$k" in ts) H_ts=$v;; up) H_up=$v;; mqtt) H_mqtt=$v;; mqtt_broker) H_broker=$v;; app_ok) H_ok=$v;; esac
  done < "$HEALTH"
  return 0
}
health_age() { # pose H_age (s) d'apres l'uptime ecrit par l'application, sinon d'apres l'horloge
  toint H_up 0; toint H_ts 0
  if [ "$H_up" -gt 0 ]; then H_age=$(( UP - H_up )); [ "$H_age" -lt 0 ] && H_age=999999
  else H_age=$(( $(now) - H_ts )); fi
}
mem_avail() { MA=0; while read -r k v u; do case "$k" in MemAvailable:) MA=$v; break;; esac; done < /proc/meminfo; }
# place libre (Kio) d'un montage : un seul programme (df -P, une ligne par montage) et une lecture interne, pas d'awk (sobriete, G18)
free_kb() { df -kP "$1" 2>/dev/null | { read -r _h; read -r _a _b _c _d _e; case "$_d" in ''|*[!0-9]*) ;; *) echo "$_d";; esac; }; }
child_alive() { live_child; }     # l'application lancee par le lanceur tourne-t-elle encore (meme numero, meme nom) ?
is_launcher() { [ "$(head -c 2 "$LAUNCHER" 2>/dev/null)" = '#!' ]; }   # /data/openqiarad est-il encore le lanceur ?
seen_health() { [ -e "$(sd "$1")/HEALTH_SEEN" ]; }                      # cette version a-t-elle deja ecrit sa sante ?
note_health() { [ "$1" = media-old ] || [ "$1" = none ] || seen_health "$1" || true 2>/dev/null > "$(sd "$1")/HEALTH_SEEN"; }
hang_kill() { # hang_kill raison : arret force compte comme un echec (essai : retour arriere apres TRIAL_HANG_MAX)
  if [ -e "$ST/trial" ] && [ "$rsl" = new ]; then :
  elif ! rate_ok hangkill "$HANG_MAX_HOUR" 3600; then log "application figee ($1) mais deja $HANG_MAX_HOUR arrets en 1 h : rien de plus"; return 0
  fi
  hang_kills=$((hang_kills + 1))
  log "application figee ($1) : arret force ($hang_kills)"
  stop_child; rm -f "$ST/expected_stop"     # un blocage compte comme un echec pour le lanceur
  if [ -e "$ST/trial" ] && [ "$hang_kills" -ge "$TRIAL_HANG_MAX" ]; then
    sh "$QP/qp-update" rollback "essai fige" >> "$LOG" 2>&1; hang_kills=0
  fi
}
listening() { # pose L22 et L2222 (SSH de secours, « off » sans lui) d'apres /proc/net/tcp (etat 0A = ecoute)
  L22=0; L2222=0; _hx=$(printf '%04X' "$SSH_SECOURS_PORT" 2>/dev/null)
  while read -r _sl _la _ra _st _rest; do
    case "$_st:$_la" in 0A:*:0016) L22=1;; 0A:*:"$_hx") [ "$SSH_SECOURS_PORT" -gt 0 ] && L2222=1;; esac
  done < "$NET_TCP"
  [ "$SSH_SECOURS_PORT" -gt 0 ] || L2222=off
}
gateway() { # passerelle par defaut d'apres /proc/net/route (hexadecimal petit-boutiste)
  [ -n "$GATEWAY" ] && { GW=$GATEWAY; return; }
  GW=
  while read -r _if _dst _gw _rest; do
    [ "$_dst" = 00000000 ] && [ "$_gw" != 00000000 ] && { GW="$((0x$_gw & 255)).$((0x$_gw >> 8 & 255)).$((0x$_gw >> 16 & 255)).$((0x$_gw >> 24 & 255))"; break; }
  done < /proc/net/route 2>/dev/null
}
passive() { [ "$PASSIVE" = 1 ] && { log "(passif, non fait) $*"; return 0; }; return 1; }
stop_child() { # arret volontaire : le lanceur ne le comptera pas comme un plantage
  passive "arret de l'application" && return 0
  live_child || { log "arret demande mais aucune application en cours (numero absent ou perime) : rien fait"; return 0; }
  true 2>/dev/null > "$ST/expected_stop"
  kill "$CH" 2>/dev/null
  _i=0; while [ $_i -lt 8 ] && kill -0 "$CH" 2>/dev/null; do sleep 1; _i=$((_i+1)); done
  kill -0 "$CH" 2>/dev/null && kill -9 "$CH" 2>/dev/null
  return 0
}
rate_ok() { # rate_ok nom max fenetre : autorise si moins de max fois sur la fenetre ; en cas de doute, compte
  # v6 : chaque evenement est note "uptime:horloge:boot_id". Son age se mesure sur l'uptime dans le meme demarrage (l'horloge
  # murale part de 1970 et saute au reglage NTP : avec elle, le saut faisait oublier tous les evenements passes), sur l'horloge
  # apres un redemarrage si elle est plausible des deux cotes, et sinon il vaut l'uptime courant (l'evenement date d'avant ce
  # demarrage : il reste compte jusqu'a ce que la camera ait tourne toute la fenetre). Les anciens fichiers (horloge seule)
  # sont lus comme des evenements d'un autre demarrage.
  _f=$ST/rate_$1; _keep=; _n=0; _line=
  up_now; boot_id; _t=$(now)
  [ -s "$_f" ] && read -r _line < "$_f"
  for _x in $_line; do
    case "$_x" in
      *:*:*) _xu=${_x%%:*}; _xr=${_x#*:}; _xw=${_xr%%:*}; _xb=${_xr#*:} ;;
      *) _xu=0; _xw=$_x; _xb=; toint _xw 0; [ "$_xw" -gt 1700000000 ] || continue ;;   # ancien format : horloge plausible seulement (comme en v5)
    esac
    toint _xu 0; toint _xw 0
    [ "$_xu" -gt 0 ] || [ "$_xw" -gt 0 ] || continue      # jeton illisible : ignore
    if [ -n "$_xb" ] && [ "$_xb" = "$BOOT" ]; then _age=$((UP - _xu)); [ "$_age" -lt 0 ] && _age=0
    elif [ "$_t" -gt 1700000000 ] && [ "$_xw" -gt 1700000000 ] && [ "$_t" -ge "$_xw" ]; then _age=$((_t - _xw))
    else _age=$UP; fi
    [ "$_age" -lt "$3" ] && { _keep="$_keep $_x"; _n=$((_n+1)); }
  done
  if [ "$_n" -ge "$2" ]; then echo $_keep > "$_f"; return 1; fi
  echo $_keep "$UP:$_t:$BOOT" > "$_f"; return 0
}
# (v9) bounded SEC cmd... : lance la commande en arriere-plan et attend au plus SEC secondes ; au-dela, l'arrete (TERM puis KILL)
# et journalise. Le surveillant est une boucle a un seul fil : une commande qui ne rend pas la main (fbxupstartctl ou fbxbusctl sur
# un bus mort, sync sur une carte SD muette, demon qui ne se detache pas) la figeait jusque-la (observation du banc du 27/10/2026).
# Pas d'applet timeout sur la camera : attente par sondage de /proc/<pid>. Sortie et erreurs de la commande vers /dev/null.
bounded() {
  _bt=$1; shift
  "$@" >/dev/null 2>&1 &
  _bp=$!; _bi=0
  while [ -d "/proc/$_bp" ] && [ $_bi -lt "$_bt" ]; do sleep 1; _bi=$((_bi+1)); done
  if [ -d "/proc/$_bp" ]; then
    kill "$_bp" 2>/dev/null; sleep 1
    [ -d "/proc/$_bp" ] && { kill -9 "$_bp" 2>/dev/null; sleep 1; }
    if [ -d "/proc/$_bp" ] && ! grep -q '^State:[[:space:]]*Z' "/proc/$_bp/status" 2>/dev/null; then
      # sommeil ininterruptible (carte SD ou bus muet) : meme KILL attend la fin de l'appel systeme ; ne pas attendre avec lui
      log "commande sans reponse apres $_bt s et sourde a l'arret (entree/sortie bloquee ?) : $1 ${2-} (pid $_bp abandonne)"
      return 124
    fi
    log "commande sans reponse apres $_bt s, arretee : $1 ${2-}"
    wait "$_bp" 2>/dev/null; return 124
  fi
  wait "$_bp" 2>/dev/null
}
do_reboot() {
  passive "redemarrage ($1)" && return 1
  [ "$ENABLE_REBOOT" = 1 ] || { log "redemarrage demande ($1) mais desactive"; return 1; }
  # v6 : les ordres de Home Assistant ont leur propre budget (ORDER_REBOOT_MAX) : un client MQTT ou une automatisation ne peut
  # plus epuiser le budget des redemarrages automatiques (passerelle muette), ni l'inverse.
  case "$1" in
    "ordre HA"*) if [ "$ORDER_REBOOT_MAX" -gt 0 ] && ! rate_ok order_reboot "$ORDER_REBOOT_MAX" "$REBOOT_WINDOW"; then log "redemarrage refuse ($1) : deja $ORDER_REBOOT_MAX sur ordre en $((REBOOT_WINDOW/3600)) h"; return 1; fi ;;   # v10 : 0 = sans limite
    *) if ! rate_ok reboot "$REBOOT_MAX" "$REBOOT_WINDOW"; then log "redemarrage refuse ($1) : deja $REBOOT_MAX en $((REBOOT_WINDOW/3600)) h"; return 1; fi ;;
  esac
  case "$1" in "ordre HA"*) ;; *) snapshot "avant redemarrage : $1" ;; esac
  log "REDEMARRAGE de la camera : $1"
  put "$ST/last_reboot_reason" "$(ts) $1"
  bounded 10 sync
  ( sleep 1; reboot; sleep 25; echo b > "$SYSRQ" ) &
  return 0
}
wifi_l1() { passive "Wi-Fi niveau 1 ($1)" && return 1; [ "$ENABLE_WIFI_ACTIONS" = 1 ] || return 1
  log "Wi-Fi niveau 1 ($1) : deconnexion, hlconnman se reassocie"
  bounded 15 fbxbusctl call hlconnman wifi_disconnect; }
wifi_l2() { passive "Wi-Fi niveau 2 ($1)" && return 1; [ "$ENABLE_WIFI_ACTIONS" = 1 ] || return 1
  log "Wi-Fi niveau 2 ($1) : rechargement du pilote (fbxupstartctl restart hlconnman)"
  bounded 20 fbxupstartctl restart hlconnman; }
# (v8) dropbear 2222, celui de Qiara Plus : lance avec un maintien de connexion (-K 30 : un paquet de maintien toutes les 30 s,
# la session tombe au bout de 3 silences au lieu de rester a jamais ouverte derriere un Wi-Fi coupe) ; -s sans mot de passe,
# -g pas de mot de passe pour root (cle seulement). Le numero du processus d'ecoute est dans DROPBEAR_PID.
DROPBEAR_PID=${QP_DROPBEAR_PID:-/var/run/dropbear-2222.pid}
start_dropbear_2222() { [ "$SSH_SECOURS_PORT" -gt 0 ] || return 0; bounded 10 "$DROPBEAR" -s -g -p "$SSH_SECOURS_PORT" -K 30 -P "$DROPBEAR_PID"; }   # dropbear se detache de lui-meme ; borne par securite (v9)
# (v8) ordre ssh-restart de Home Assistant : relance des deux ecoutes SSH, celle de Qiara Plus (2222 : arret du processus dont le
# numero est dans le fichier pid, seulement s'il porte le nom dropbear, puis relance) et celle du constructeur (22 : fbxupstartctl
# restart dropbear). Les sessions deja ouvertes sont des processus a part : elles ne sont pas touchees. Le dropbear d'origine
# tarde parfois a rendre sa banniere alors que celui de Qiara Plus repond (27/10/2026) : cet ordre est le remede sans redemarrage.
ssh_restart() {
  passive "relance de dropbear 22 et 2222 ($1)" && return 0
  rd _dp "$DROPBEAR_PID" 0; toint _dp 0
  if [ "$_dp" != 0 ] && [ "$SSH_SECOURS_PORT" -gt 0 ]; then
    _dc=; read -r _dc < "/proc/$_dp/comm" 2>/dev/null
    if [ "$_dc" = dropbear ]; then
      kill "$_dp" 2>/dev/null
      # (v9) attendre l'arret effectif (5 s au plus, puis KILL) : sinon la nouvelle ecoute 2222 echouait en silence
      _bi=0; while [ -d "/proc/$_dp" ] && [ $_bi -lt 5 ]; do sleep 1; _bi=$((_bi+1)); done
      [ -d "/proc/$_dp" ] && { kill -9 "$_dp" 2>/dev/null; sleep 1; log "dropbear 2222 : ancien processus $_dp arrete de force"; }
    else log "dropbear 2222 : numero $_dp perime (processus ${_dc:-absent}), pas d'arret"; fi
  fi
  start_dropbear_2222
  bounded 20 fbxupstartctl restart dropbear
  sleep 1; listening
  log "dropbear 22 et 2222 relances ($1) : ecoute 22=$L22 2222=$L2222"
  [ "$L2222" = 0 ] && log "dropbear 2222 n'ecoute pas apres la relance : nouvel essai au prochain passage lent"
}
# v4 : instantane d'incident. La boite noire (/tmp/bb.log), dmesg et l'etat du reseau vivent en memoire vive : un
# redemarrage les efface (incident de 20 h 28 le 26/10/2026). Copies sur /media/qp/incidents (6 gardes, ~1 Mo chacun),
# repli sur /data/qp/incident (un seul, petit) si /media ne repond pas. Pris au rechargement du pilote Wi-Fi, avant un
# redemarrage automatique et au retour d'une coupure d'au moins INCIDENT_MIN_SEC.
INCIDENTS=${QP_INCIDENTS:-$BULK/incidents}
INCIDENT_KEEP=6
snapshot() {
  passive "instantane ($1)" && return 0
  _small=; _d=$INCIDENTS/$(date '+%Y%m%d-%H%M%S')
  if ! mkdir -p "$_d" 2>/dev/null || ! : > "$_d/.ok" 2>/dev/null; then
    _small=1; _d=$QP/incident; rm -rf "$_d"; mkdir -p "$_d" 2>/dev/null || return 0
  fi
  rm -f "$_d/.ok"
  { echo "raison=$1"; echo "uptime=$UP"; date; echo "--- surveillant"; cat "$STATUS"; echo "--- sante"; cat "$HEALTH"
    echo "--- memoire"; grep -E '^(MemFree|MemAvailable|Cached|Slab|SUnreclaim):' /proc/meminfo; cat /proc/loadavg; } > "$_d/etat.txt" 2>&1
  dmesg 2>/dev/null | tail -n 300 > "$_d/dmesg.txt"
  { echo "--- interfaces"; cat /proc/net/dev; cat /proc/net/wireless; echo "--- routes"; cat /proc/net/route; echo "--- arp"; cat /proc/net/arp
    echo "--- tcp"; cat /proc/net/tcp; cat /proc/net/tcp6; echo "--- snmp"; cat /proc/net/snmp; } > "$_d/reseau.txt" 2>&1
  for _p in /proc/[0-9]*; do read -r _c < "$_p/comm" 2>/dev/null || continue
    echo "${_p#/proc/} $_c $(grep -E '^(State|VmRSS):' "$_p/status" 2>/dev/null | tr -s ' \t\n' ' ')"; done > "$_d/processus.txt" 2>&1
  if [ -z "$_small" ]; then
    tail -c 524288 "$BBLOG" > "$_d/bb.log" 2>/dev/null; tail -n 400 "$LOG" > "$_d/journal.log" 2>/dev/null
    # v6 : les dossiers dates de 1970 (horloge pas encore reglee) sont comptes et elagues comme les autres
    _n=$(ls -d "$INCIDENTS"/[0-9]* 2>/dev/null | wc -l)
    [ "$_n" -gt "$INCIDENT_KEEP" ] && ls -d "$INCIDENTS"/[0-9]* | sort | head -n $((_n - INCIDENT_KEEP)) | while read -r _o; do rm -rf "$_o"; done
  else
    tail -c 32768 "$BBLOG" > "$_d/bb.log" 2>/dev/null
  fi
  bounded 10 sync
  log "instantane d'incident ($1) : $_d"
}
video_check() { # reglages effectifs de hlcamd (diagnostic seulement, aucune action) ; v8 : codec demande (--use-h264/--use-h265)
  V_pid=; V_iv=?; V_rate=defaut; V_gop=defaut; V_shim=0; V_codec=defaut
  for _p in /proc/[0-9]*; do read -r _c < "$_p/comm" 2>/dev/null && [ "$_c" = hlcamd ] && { V_pid=${_p#/proc/}; break; }; done
  [ -n "$V_pid" ] || { V_iv=absent; V_codec=absent; return; }
  set -- $(tr '\0' ' ' < /proc/$V_pid/cmdline 2>/dev/null)
  while [ $# -gt 0 ]; do
    case "$1" in --iv-detection) V_iv=$2; shift;; --1080p-bitrate) V_rate=$2; shift;; --gop-denum) V_gop=$2; shift;;
                 --use-h264) V_codec=h264;; --use-h265) V_codec=h265;; esac
    shift
  done
  while read -r _l; do case "$_l" in *qiara_shim*) V_shim=1; break;; esac; done < /proc/$V_pid/maps 2>/dev/null
}

# (v7) hlcamd absent depuis VIDEO_GONE_SEC : redemarrage de la camera. OpenQiara ne compte plus hlcamd dans la sante qui
# nourrit le chien de garde materiel (hlcamd absent = redemarrage toutes les 5 a 6 min et radio coupee a chaque fois) ; c'est ici
# que la video est reparee, avec le budget REBOOT_MAX sur REBOOT_WINDOW (do_reboot : instantane d'abord, journal, mode passif respecte).
# Un redemarrage refuse (budget, desactive, passif) n'est retente qu'apres un autre VIDEO_GONE_SEC. Sans /proc lisible : rien.
video_gone_check() {
  if [ "$VIDEO_GONE_SEC" -le 0 ] || [ "$V_iv" != absent ] || ! [ -r /proc/1/comm ]; then
    [ "$hl_gone_since" -ge 0 ] && [ "$V_iv" != absent ] && [ "$VIDEO_GONE_SEC" -gt 0 ] && log "hlcamd de nouveau present apres $((UP - hl_gone_since)) s"
    hl_gone_since=-1; hl_try_at=-999999; return 0
  fi
  [ "$hl_gone_since" -ge 0 ] || { hl_gone_since=$UP; log "hlcamd absent"; return 0; }
  _d=$((UP - hl_gone_since))
  [ "$_d" -ge "$VIDEO_GONE_SEC" ] && [ $((UP - hl_try_at)) -ge "$VIDEO_GONE_SEC" ] || return 0
  hl_try_at=$UP
  do_reboot "video absente (hlcamd) depuis $_d s"
  return 0
}

# Boite noire de l'enquete SSH (v7) : relancee si elle est installee ($QP/bb.sh) et activee ($QP/bb.on), y compris apres
# un redemarrage ; 4 lancements par heure au plus. Elle ne vit qu'en memoire vive (journal /tmp/bb.log plafonne a ~2 Mo).
BB=off
BBPID=${QP_BB_PID:-/tmp/bb.pid}
BBLOG=${QP_BB_LOG:-/tmp/bb.log}
bb_check() {
  [ -f "$QP/bb.on" ] && [ -s "$QP/bb.sh" ] || { BB=off; return 0; }
  rd _bbp "$BBPID" 0; toint _bbp 0
  if [ "$_bbp" != 0 ] && kill -0 "$_bbp" 2>/dev/null && grep -q bb.sh "/proc/$_bbp/cmdline" 2>/dev/null; then BB=1; return 0; fi
  BB=0
  passive "lancement de la boite noire" && return 0
  rate_ok bbstart 4 3600 || return 0
  log "boite noire absente : lancement"
  ( setsid nohup sh "$QP/bb.sh" >/dev/null 2>&1 < /dev/null & )
  BB=1
}
# Echantillons de la detection de personnes interne (/tmp/vision.samples, 2,4 Mo de memoire vive) : crees au demarrage par
# le premier lancement de hlcamd (reglages du constructeur) et inutiles une fois la video relancee sans cette detection.
# Retires seulement si la detection est coupee depuis 5 min et qu'aucun processus ne les ouvre ni ne les projette.
SAMPLES=${QP_SAMPLES:-/tmp/vision.samples}
SAMPLES_AFTER=$(int "${QP_SAMPLES_AFTER:-300}" 300)
iv_off_since=0
samples_check() {
  if [ "$V_iv" != 0 ] || [ -z "$V_pid" ]; then iv_off_since=0; return 0; fi
  [ "$iv_off_since" = 0 ] && iv_off_since=$UP
  [ -f "$SAMPLES" ] && [ $((UP - iv_off_since)) -ge "$SAMPLES_AFTER" ] || return 0
  ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q "${SAMPLES##*/}" && return 0
  grep -q "${SAMPLES##*/}" /proc/[0-9]*/maps 2>/dev/null && return 0
  passive "retrait de $SAMPLES" && return 0
  _k=$(( $(wc -c < "$SAMPLES" 2>/dev/null || echo 0) / 1024 ))
  rm -f "$SAMPLES" && log "detection interne coupee : $SAMPLES retire (${_k} Kio de memoire rendus)"
}

# --- etat de la boucle (instants en secondes d'uptime, 0 = rien en cours) ---
dead_since=0; mem_low_since=0; mq_down_since=0; net_down_since=0; hang_kills=0; l1=0; l2=0; l3_at=-999999
last_net=-999999; last_slow=-999999; net_ok=1; GW=; gw_at=-999999; hl_gone_since=-1; hl_try_at=-999999
V_pid=; V_iv=?; V_rate=?; V_gop=?; V_shim=?; V_codec=?; L22=?; L2222=?; FD=?; FM=?
_om="ordres HA de redemarrage sans limite (v10)"; [ "$ORDER_REBOOT_MAX" -gt 0 ] && _om="ordres HA de redemarrage : $ORDER_REBOOT_MAX par $((REBOOT_WINDOW/3600)) h au plus"
log "surveillant demarre (pid $$) ; $_om"

while :; do
  up_now
  echo "$UP" > "$RUN/guard_beat"

  # (5) ordres de Home Assistant
  for c in "$CMD"/*; do
    [ -e "$c" ] || continue
    n=${c##*/}
    [ -f "$c" ] || { rm -rf "$c"; log "ordre ignore (pas un fichier) : $n"; continue; }     # v6
    rm -f "$c"
    case "$n" in
      restart-app)     rate_ok order_restart 6 3600 || { log "ordre HA refuse (6 relances par heure au plus) : $n"; continue; }
                       log "ordre HA : relance de l'application"; stop_child ;;
      wifi-bounce)     rate_ok order_wifi 6 3600 || { log "ordre HA refuse (6 ordres Wi-Fi par heure au plus) : $n"; continue; }
                       log "ordre HA : Wi-Fi"; wifi_l1 "ordre HA" ;;
      wifi-driver)     rate_ok order_wifi 6 3600 || { log "ordre HA refuse (6 ordres Wi-Fi par heure au plus) : $n"; continue; }
                       log "ordre HA : pilote Wi-Fi"; wifi_l2 "ordre HA" ;;
      ssh-restart)     rate_ok order_ssh 6 3600 || { log "ordre HA refuse (6 relances SSH par heure au plus) : $n"; continue; }     # v8
                       log "ordre HA : relance SSH"; ssh_restart "ordre HA" ;;
      reboot)          do_reboot "ordre HA" ;;
      reboot-installation) do_reboot "ordre HA (fin d'installation OpenQIARA Claude V15)" ;;
      reboot-reglage)  do_reboot "ordre HA (changement de reglage video, reglage.sh)" ;;
      update-rollback) passive "retour arriere" || sh "$QP/qp-update" rollback "ordre HA" >> "$LOG" 2>&1 ;;
      update-promote)  passive "validation" || sh "$QP/qp-update" promote --force >> "$LOG" 2>&1 ;;
      use-prev)        rate_ok order_restart 6 3600 || { log "ordre HA refuse (6 relances par heure au plus) : $n"; continue; }     # v6
                       passive "retour a la version precedente" || sh "$QP/qp-update" use-prev >> "$LOG" 2>&1 ;;
      *)               log "ordre inconnu ignore : $n" ;;
    esac
  done

  # (1) et (2) l'application
  hv=0
  if child_alive; then
    dead_since=0
    rd rs "$ST/run_up" 0; rd rb "$ST/run_boot" ""; rd rsl "$ST/running_slot" none; boot_id
    toint rs 0; if [ "$rb" = "$BOOT" ]; then age=$(( UP - rs )); else age=0; fi
    # sante valable seulement si elle a ete ecrite pendant CE lancement (une version sans fichier de sante
    # lancee apres une version qui en ecrivait ne doit jamais etre jugee sur l'ancien fichier)
    if health_read; then toint H_up 0; [ "$rb" = "$BOOT" ] && [ "$H_up" -ge "$rs" ] && hv=1; fi
    if [ "$hv" = 1 ]; then
      health_age
      [ "$H_age" -lt 60 ] && [ "$H_ok" = 1 ] && note_health "$rsl"
      if [ "$age" -ge "$HEALTH_GRACE" ] && [ "$H_age" -gt "$HEALTH_STALE" ]; then
        hang_kill "sante vieille de ${H_age} s"
      elif [ -e "$ST/trial" ] && [ "$rsl" = new ] && [ "$age" -ge "$PROMOTE_AFTER" ] && [ "$H_age" -lt 60 ] && [ "$H_ok" = 1 ] && [ "${H_mqtt:-1}" != 0 ]; then
        sh "$QP/qp-update" promote >> "$LOG" 2>&1; hang_kills=0      # validation : sante bonne ET liaison MQTT active
      fi
    elif [ "$age" -ge "$HEALTH_GRACE" ] && { { [ -e "$ST/trial" ] && [ "$rsl" = new ]; } || seen_health "$rsl"; }; then
      hang_kill "aucune sante ${age} s apres le lancement"       # essai, ou version qui ecrivait sa sante
    fi
  else
    [ "$dead_since" = 0 ] && dead_since=$UP
    if [ $((UP - dead_since)) -ge "$DEAD_SEC" ]; then
      if ! is_launcher; then
        log "application non suivie et $LAUNCHER n'est plus le lanceur (mise a jour par l'interface ?) : aucun lancement"
      else passive "lancement de l'application" || {
        log "application absente depuis ${DEAD_SEC} s : lancement par le surveillant"
        ( nohup "$LAUNCHER" -web :80 -log /data/openqiarad.log >/dev/null 2>&1 & ); }
      fi
      dead_since=0
    fi
  fi

  # memoire disponible
  mem_avail
  if [ "$MA" -gt 0 ] && [ "$MA" -lt "$MEM_MIN_KB" ]; then
    [ "$mem_low_since" = 0 ] && mem_low_since=$UP
    if [ $((UP - mem_low_since)) -ge "$MEM_LOW_SEC" ]; then
      if rate_ok memrestart 2 3600; then log "memoire disponible basse (${MA} Kio) depuis $MEM_LOW_SEC s : relance de l'application"; stop_child; fi
      mem_low_since=0
    fi
  else mem_low_since=0; fi

  # (4) reseau
  iv=$NET_CHECK_SEC; [ "$net_ok" = 0 ] && iv=$TICK
  if [ $((UP - last_net)) -ge "$iv" ]; then
    last_net=$UP
    [ $((UP - gw_at)) -ge 600 ] || [ -z "$GW" ] && { gateway; gw_at=$UP; }
    if [ -n "$GW" ] && ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
      if [ "$net_ok" = 0 ]; then
        log "passerelle de nouveau joignable apres $((UP - net_down_since)) s"
        [ $((UP - net_down_since)) -ge "$INCIDENT_MIN_SEC" ] && snapshot "coupure de $((UP - net_down_since)) s terminee"
      fi
      net_ok=1; net_down_since=0; l1=0; l2=0; l3_at=-999999
    else
      [ "$net_ok" = 1 ] && { net_down_since=$UP; log "passerelle ${GW:-inconnue} muette"; }
      net_ok=0; d=$((UP - net_down_since))
      # v6 : un redemarrage refuse (plafond, desactive, passif) n'est retente qu'apres NET_L3_SEC, au lieu de chaque tour (journal)
      if [ "$d" -ge "$NET_L3_SEC" ]; then [ $((UP - l3_at)) -ge "$NET_L3_SEC" ] && { l3_at=$UP; do_reboot "passerelle muette depuis $d s" && net_down_since=$UP; }
      elif [ "$d" -ge "$NET_L2_SEC" ] && [ "$l2" = 0 ]; then snapshot "passerelle muette depuis $d s"; wifi_l2 "passerelle muette depuis $d s"; l2=1
      elif [ "$d" -ge "$NET_L1_SEC" ] && [ "$l1" = 0 ]; then wifi_l1 "passerelle muette depuis $d s"; l1=1
      fi
    fi
  fi
  # MQTT coupe alors que le reseau va bien ET que le serveur MQTT accepte les connexions : probleme de l'application
  # (Home Assistant arrete ou injoignable : aucune relance, elle ne servirait a rien)
  if [ "$net_ok" = 1 ] && [ "$hv" = 1 ] && [ "$H_age" -lt 60 ] && [ "$H_mqtt" = 0 ] && [ "$H_broker" = 1 ]; then
    [ "$mq_down_since" = 0 ] && mq_down_since=$UP
    if [ $((UP - mq_down_since)) -ge "$MQTT_RESTART_SEC" ]; then
      if rate_ok mqttrestart 2 3600; then
        log "MQTT coupe depuis $((UP - mq_down_since)) s alors que le serveur repond : relance de l'application"; stop_child
      else log "MQTT coupe depuis $((UP - mq_down_since)) s : deja 2 relances en 1 h, rien de plus"; fi
      mq_down_since=0
    fi
  else mq_down_since=0; fi

  # (3) et (6) controles espaces
  if [ $((UP - last_slow)) -ge "$SLOW_SEC" ]; then
    last_slow=$UP
    listening
    [ "$L2222" = 0 ] && { passive "relance du SSH de secours" || { log "SSH de secours (port $SSH_SECOURS_PORT) absent : relance"; start_dropbear_2222; }; }
    [ "$L22" = 1 ] || passive "relance de dropbear 22" || { log "dropbear 22 absent : relance"; bounded 20 fbxupstartctl start dropbear; }
    FD=$(free_kb /data)
    FM=$(free_kb "${QP_MEDIA_DF:-/media}")   # v6 : /media (incident du 26/10 a 92 %)
    if [ -n "$FD" ] && [ "$FD" -lt 1500 ] && ! passive "vidage des journaux"; then
      log "place sur /data basse (${FD} Kio) : journaux vides"
      for f in /data/hlcamd.log /data/dnsmasq.log /data/post_boot.log /data/boot_debug.log; do [ -f "$f" ] && true 2>/dev/null > "$f"; done
    fi
    video_check; video_gone_check
    rd rsl "$ST/running_slot" none; last_result; ures=$_lr; rd lrb "$ST/last_reboot_reason" aucun
    bb_check; samples_check
    {
      echo "ts=$(now)"; echo "up=$UP"
      echo "net_ok=$net_ok"; echo "net_down_s=$([ "$net_ok" = 0 ] && echo $((UP - net_down_since)) || echo 0)"
      echo "mem_avail_kb=$MA"; echo "data_free_kb=${FD:-?}"; echo "media_free_kb=${FM:-?}"
      echo "ssh22=$L22"; echo "ssh2222=$L2222"
      echo "hang_kills=$hang_kills"; echo "slot=$rsl"; echo "trial=$([ -e "$ST/trial" ] && echo 1 || echo 0)"
      echo "update_result=$ures"; echo "last_reboot=$lrb"
      echo "video_iv=$V_iv"; echo "video_bitrate=$V_rate"; echo "video_gop_denum=$V_gop"; echo "video_shim=$V_shim"; echo "video_codec=$V_codec"
      echo "launcher_ok=$(is_launcher && echo 1 || echo 0)"
      echo "bb=$BB"
    } > "$STATUS.tmp" 2>/dev/null && mv -f "$STATUS.tmp" "$STATUS"
  fi

  [ -n "$QP_ONCE" ] && { [ "$QP_ONCE" -le 1 ] && exit 0; QP_ONCE=$((QP_ONCE - 1)); }
  sleep "$TICK"
done
