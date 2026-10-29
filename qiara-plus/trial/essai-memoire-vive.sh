#!/bin/sh
# Essai de la nouvelle version d'OpenQiara EN MEMOIRE VIVE (Claude, 26/10/2026).
# Rien n'est ecrit sur la carte SD ni la flash : binaire, configuration copiee, journaux et etat sont dans un
# tmpfs ($T). La boucle de boot.sh est suspendue (SIGSTOP) puis reprise (SIGCONT) : l'ancienne version revient
# d'elle-meme. Retour automatique a la fin de la duree, si la nouvelle version s'arrete, ou si $T/STOP existe.
# Usage : sh essai-memoire-vive.sh DUREE_S        (le binaire doit deja etre dans $T/oq5)
T=${QPT:-/tmp/qpt}
DUR=${1:-900}
APP=${QPT_APP:-/data/openqiarad}
CFG=${QPT_CFG:-/data/openqiara.json}
PORT=${QPT_WEB:-:80}
L=$T/essai.log
NEWPID=; GPID=; PP=
now_up() { read -r u _ < /proc/uptime; echo "${u%%.*}"; }
say() { echo "$(date '+%H:%M:%S') $*" >> "$L"; }
comm_pid() { for p in /proc/[0-9]*; do read -r c < $p/comm 2>/dev/null; [ "$c" = "$1" ] && alive "${p#/proc/}" && { echo "${p#/proc/}"; return 0; }; done; return 1; }
alive() { [ -e /proc/$1/status ] && ! grep -q '^State:[[:space:]]*Z' /proc/$1/status; }   # un zombie ne compte pas
mem_of() { awk '/^VmRSS|^RssAnon|^RssFile|^RssShmem|^Threads/{printf "%s%s ", $1, $2}' /proc/$1/status 2>/dev/null; }
restore() {
  say "retour : $1"
  [ -n "$GPID" ] && kill "$GPID" 2>/dev/null
  if [ -n "$NEWPID" ] && alive "$NEWPID"; then
    kill "$NEWPID" 2>/dev/null; i=0; while [ $i -lt 15 ] && alive "$NEWPID"; do sleep 1; i=$((i+1)); done
    alive "$NEWPID" && kill -9 "$NEWPID" 2>/dev/null
  fi
  if [ -n "$PP" ] && kill -0 "$PP" 2>/dev/null; then
    kill -CONT "$PP"; say "boucle de boot.sh reprise (pid $PP)"
  else
    say "boucle de boot.sh introuvable : boucle de remplacement"
    ( nohup sh -c "while :; do $APP -web $PORT -log /data/openqiarad.log >/dev/null 2>&1; sleep 10; done" >/dev/null 2>&1 & )
  fi
  i=0; while [ $i -lt 60 ]; do sleep 2; i=$((i+2)); o=$(comm_pid openqiarad) && break; done
  if [ -n "$o" ]; then say "ancienne version revenue (pid $o, $(readlink /proc/$o/exe)) apres ${i} s"; else say "ATTENTION : ancienne version absente apres 60 s"; fi
  say "fin de l'essai"
  exit 0
}
trap 'restore "signal recu"' TERM INT    # pas HUP : la fin de la session SSH ne doit pas interrompre l'essai

mkdir -p "$T/cfg" "$T/qp/state" "$T/run" "$T/bulk/slots/essai"
true > "$L"
[ -x "$T/oq5" ] || { say "binaire absent dans $T/oq5"; exit 1; }
say "essai de $DUR s : $($T/oq5 -version 2>&1)"
cp "$CFG" "$T/cfg/openqiara.json" && chmod 600 "$T/cfg/openqiara.json" || { say "copie de la configuration impossible"; exit 1; }
[ -f "$(dirname "$CFG")/openqiara_rtsp_h264_params" ] && cp "$(dirname "$CFG")/openqiara_rtsp_h264_params" "$T/cfg/"
OLD=$(comm_pid openqiarad) || { say "ancienne version introuvable"; exit 1; }
PP=$(awk '/^PPid:/{print $2}' /proc/$OLD/status)
say "ancienne version pid $OLD ($(mem_of $OLD)), boucle pid $PP : $(tr '\0' ' ' < /proc/$PP/cmdline)"
say "memoire avant : $(awk '/MemAvailable|MemFree/{printf "%s%s ", $1, $2}' /proc/meminfo)"
kill -STOP "$PP" || { say "suspension de la boucle impossible"; exit 1; }
kill "$OLD"; i=0; while [ $i -lt 15 ] && alive "$OLD"; do sleep 1; i=$((i+1)); done
alive "$OLD" && kill -9 "$OLD"
say "ancienne version arretee apres ${i} s"
# Qiara Plus en mode passif, dans le tmpfs : sante, diagnostic et boutons verifies sans aucune action
cat > "$T/qp/guard.conf" <<EOC
PASSIVE=1
ENABLE_WIFI_ACTIONS=0
ENABLE_REBOOT=0
TICK=10
SLOW_SEC=60
EOC
export QP="$T/qp" QP_RUN="$T/run" QP_BULK="$T/bulk" GOGC=75 GOMEMLIMIT=32MiB     # tout dans le tmpfs, jamais /data ni /media
"$T/oq5" -config "$T/cfg/openqiara.json" -web "$PORT" -log "$T/oq5.log" -log-level "${QPT_LEVEL:-debug}" -log-max-mb 1 -log-max-backups 2 >/dev/null 2>&1 &
NEWPID=$!
read -r BID < /proc/sys/kernel/random/boot_id
echo "$NEWPID" > "$T/qp/state/child"; echo essai > "$T/qp/state/running_slot"; echo good > "$T/qp/state/active"
now_up > "$T/qp/state/run_up"; echo "$BID" > "$T/qp/state/run_boot"
say "nouvelle version lancee pid $NEWPID"
if [ -f "$T/qp/qp-guard" ]; then
  QP_LOG="$T/guard.log" QP_BULK="$T/bulk" QP_LAUNCHER=/bin/true QP_APP_COMM=oq5 sh "$T/qp/qp-guard" >/dev/null 2>&1 &
  GPID=$!; say "surveillant passif pid $GPID"
fi
t0=$(now_up)
while :; do
  sleep 30
  [ -e "$T/STOP" ] && restore "ordre d'arret"
  alive "$NEWPID" || restore "la nouvelle version s'est arretee"
  h=$(tr '\n' ' ' < "$T/run/health" 2>/dev/null)
  say "t=$(( $(now_up) - t0 )) s | $(mem_of $NEWPID)| $(awk '/MemAvailable/{printf "%s%s", $1, $2}' /proc/meminfo) | sante: $h"
  [ $(( $(now_up) - t0 )) -ge "$DUR" ] && restore "duree ecoulee"
done
