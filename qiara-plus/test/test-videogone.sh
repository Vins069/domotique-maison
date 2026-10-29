#!/bin/bash
# Essais a blanc de la regle video de Qiara Plus v7 (v6 + hlcamd absent) : redemarrage borne par le budget.
# Banc : shell reel, chroot (QP_BENCH_ROOT, par defaut /tmp/camroot -> /), rien sur la camera. A lancer avec bash.
HERE=$(cd "$(dirname "$0")" && pwd)
export QP_DIST=${QP_DIST:-$HERE/../dist}
. "$HERE/lib.sh"
A=$T/qp/state; R=$T/run
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=3600" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "$@" > $T/qp/guard.conf; }
G9ENV="QP_BB_PID=/tmp/qptest/bb.pid QP_BB_LOG=/tmp/qptest/bb.log QP_SAMPLES=/tmp/qptest/vision.samples"
guard9() { run "$ENVV $G9ENV QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
nreboot() { grep -c '/reboot' $T/calls; }
fakehlcamd() { printf '#!/bin/sh\nsleep 60\n' > $T/hlcamd; chmod +x $T/hlcamd
  chroot $ROOT /tmp/qptest/hlcamd -d 75 --iv-detection 0 --1080p-bitrate 1500000 --gop-denum 2 & HP=$!; sleep 0.5; }
killhl() { kill $HP 2>/dev/null; wait $HP 2>/dev/null; }
# aucun hlcamd reel ne doit tourner sur le banc
if grep -qx hlcamd /proc/[0-9]*/comm 2>/dev/null; then echo "un hlcamd tourne sur le banc : abandon"; exit 2; fi

echo "V1 : hlcamd absent depuis plus que VIDEO_GONE_SEC -> un redemarrage, journalise avec sa raison"
# REBOOT_MAX=1 : le faux reboot ne redemarre rien, et sur un banc rapide six tours de boucle couvrent deux fois
# VIDEO_GONE_SEC, d'ou une seconde tentative legitime (V5 eprouve le refus du budget) ; ici seul le premier redemarrage compte.
reset; conf VIDEO_GONE_SEC=3 REBOOT_MAX=1
ONCE=6 guard9 >/dev/null 2>&1; sleep 2
[ "$(nreboot)" = 1 ] && ok "redemarrage demande une fois" || ko "redemarrages : $(nreboot)"
grep -q "REDEMARRAGE de la camera : video absente (hlcamd) depuis" $T/log && ok "raison journalisee" || ko "pas de raison : $(tail -3 $T/log)"
grep -q "^hlcamd absent\|hlcamd absent" $T/log && ok "debut d'absence journalise" || ko "debut non journalise"
d=$(ls -d $T/bulk/incidents/2* 2>/dev/null | head -1)
[ -n "$d" ] && grep -q '^raison=avant redemarrage : video absente' $d/etat.txt && ok "instantane pris avant le redemarrage" || ko "instantane absent ($(ls $T/bulk/incidents 2>&1 | head -2))"

echo "V2 : absence plus courte que le seuil -> rien"
reset; conf VIDEO_GONE_SEC=100
ONCE=6 guard9 >/dev/null 2>&1; sleep 2
[ "$(nreboot)" = 0 ] && ok "aucun redemarrage" || ko "redemarrage trop tot"
grep -q "hlcamd absent" $T/log && ok "absence notee" || ko "absence non notee"

echo "Video : hlcamd present -> rien, meme apres le seuil"
reset; conf VIDEO_GONE_SEC=2; fakehlcamd
ONCE=7 guard9 >/dev/null 2>&1; sleep 2; killhl
[ "$(nreboot)" = 0 ] && ok "aucun redemarrage avec hlcamd present" || ko "redemarrage avec hlcamd present"
! grep -q "hlcamd absent" $T/log && ok "aucune absence notee" || ko "absence notee a tort"

echo "V4 : hlcamd revient avant le seuil -> rien, retour journalise"
reset; conf VIDEO_GONE_SEC=6
( sleep 3; fakehlcamd; sleep 8; killhl ) &
ONCE=10 guard9 >/dev/null 2>&1; sleep 2; wait
[ "$(nreboot)" = 0 ] && ok "aucun redemarrage" || ko "redemarrage malgre le retour"
grep -q "hlcamd de nouveau present apres" $T/log && ok "retour journalise" || ko "retour non journalise"

echo "V5 : budget REBOOT_MAX atteint -> refus journalise, pas de second redemarrage"
reset; conf VIDEO_GONE_SEC=4 REBOOT_MAX=1
read -r u0 _ < /proc/uptime; ONCE=15 guard9 >/dev/null 2>&1; read -r u1 _ < /proc/uptime; sleep 2
[ "$(nreboot)" = 1 ] && ok "un seul redemarrage" || ko "redemarrages : $(nreboot)"
grep -q "redemarrage refuse (video absente (hlcamd) depuis .*deja 1 en" $T/log && ok "refus du budget journalise" || ko "pas de refus : $(grep -c . $T/log) lignes"
# borne mesuree sur le temps ecoule (un tour dure plus d'une seconde sous emulation) : au plus un refus par VIDEO_GONE_SEC, plus un
el=$(( ${u1%%.*} - ${u0%%.*} )); bmax=$(( el / 4 + 1 ))
n=$(grep -c "redemarrage refuse" $T/log); [ "$n" -ge 1 ] && [ "$n" -le "$bmax" ] && ok "refus retente tous les VIDEO_GONE_SEC, pas a chaque tour ($n en 15 tours, $el s)" || ko "journal inonde ($n refus en $el s, borne $bmax)"

echo "V6 : redemarrages desactives / mode passif / seuil 0 -> aucune action"
reset; conf VIDEO_GONE_SEC=2 ENABLE_REBOOT=0
ONCE=7 guard9 >/dev/null 2>&1; sleep 2
[ "$(nreboot)" = 0 ] && grep -q "mais desactive" $T/log && ok "ENABLE_REBOOT=0 respecte" || ko "ENABLE_REBOOT=0 : $(nreboot)"
reset; conf VIDEO_GONE_SEC=2 PASSIVE=1
ONCE=7 guard9 >/dev/null 2>&1; sleep 2
[ "$(nreboot)" = 0 ] && grep -q "passif, non fait" $T/log && ok "mode passif respecte" || ko "mode passif : $(nreboot)"
reset; conf VIDEO_GONE_SEC=0
ONCE=7 guard9 >/dev/null 2>&1; sleep 2
[ "$(nreboot)" = 0 ] && ! grep -q "hlcamd absent" $T/log && ok "VIDEO_GONE_SEC=0 : regle coupee" || ko "VIDEO_GONE_SEC=0 : $(nreboot)"

echo "V7 : valeur invalide dans guard.conf -> defaut (600 s), jamais 0 ni 1"
reset; conf VIDEO_GONE_SEC=abc
ONCE=6 guard9 >/dev/null 2>&1; sleep 2
[ "$(nreboot)" = 0 ] && ok "pas de redemarrage avec une valeur invalide" || ko "redemarrage avec une valeur invalide"
grep -q "VIDEO_GONE_SEC" $T/log && ok "valeur invalide journalisee" || ko "valeur invalide non journalisee : $(head -3 $T/log)"
reset; conf VIDEO_GONE_SEC=1
ONCE=1 guard9 >/dev/null 2>&1; sleep 1
[ "$(nreboot)" = 0 ] && ok "seuil 1 s : pas de redemarrage au premier passage (absence notee d'abord)" || ko "redemarrage au premier passage"

summary
