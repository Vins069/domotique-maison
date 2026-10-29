#!/bin/bash
# Essais a blanc des ajouts v4 de Qiara Plus (instantanes d'incident) : chroot ARM sous qemu, rien sur la camera.
. "$(dirname "$0")/lib.sh"
A=$T/qp/state; R=$T/run
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "$@" > $T/qp/guard.conf; }
G8ENV="QP_BB_PID=/tmp/qptest/bb.pid QP_BB_LOG=/tmp/qptest/bb.log QP_SAMPLES=/tmp/qptest/vision.samples"
guard8() { run "$ENVV $G8ENV QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
inc() { ls -d $T/bulk/incidents/2* 2>/dev/null | wc -l; }

echo "W1 : coupure jusqu'au niveau 2 -> instantane complet, puis rechargement du pilote"
reset; conf NET_L1_SEC=1 NET_L2_SEC=3 NET_L3_SEC=600; touch $T/net_down
head -c 700000 /dev/urandom | base64 > $T/bb.log; echo "ligne du journal" >> $T/log
ONCE=6 guard8 >/dev/null 2>&1
d=$(ls -d $T/bulk/incidents/2* 2>/dev/null | head -1)
[ -n "$d" ] && ok "instantane cree ($(basename "$d"))" || ko "aucun instantane"
for f in etat.txt dmesg.txt reseau.txt processus.txt bb.log journal.log; do [ -s "$d/$f" ] && ok "$f present" || ko "$f absent ou vide"; done
s=$(wc -c < "$d/bb.log"); [ "$s" -le 524288 ] && [ "$s" -ge 500000 ] && ok "boite noire limitee a 512 Kio ($s)" || ko "taille boite noire $s"
grep -q '^raison=passerelle muette depuis' $d/etat.txt && ok "raison notee" || ko "raison : $(head -1 $d/etat.txt)"
grep -q "restart hlconnman" $T/calls && ok "pilote recharge apres l'instantane" || ko "pas de rechargement"
grep -q "instantane d'incident" $T/log && ok "journalise" || ko "non journalise"
[ ! -e $d/.ok ] && ok "pas de fichier temoin restant" || ko ".ok restant"

echo "W2 : retour du reseau apres une coupure longue -> instantane ; coupure breve -> rien"
reset; conf NET_L1_SEC=100 NET_L2_SEC=200 NET_L3_SEC=600 INCIDENT_MIN_SEC=2; touch $T/net_down
ONCE=12 guard8 >/dev/null 2>&1 &
sleep 4; rm -f $T/net_down; wait
[ "$(inc)" = 1 ] && grep -q '^raison=coupure de' $T/bulk/incidents/2*/etat.txt && ok "instantane au retour" || ko "$(inc) instantane(s)"
reset; conf NET_L1_SEC=100 NET_L2_SEC=200 NET_L3_SEC=600 INCIDENT_MIN_SEC=60; touch $T/net_down
ONCE=8 guard8 >/dev/null 2>&1 &
sleep 3; rm -f $T/net_down; wait
[ "$(inc)" = 0 ] && ok "coupure breve : aucun instantane" || ko "$(inc) instantane(s)"

echo "W3 : avant un redemarrage automatique -> instantane ; ordre HA -> aucun"
reset; conf NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=4 REBOOT_MAX=1; touch $T/net_down
ONCE=9 guard8 >/dev/null 2>&1; sleep 2
grep -q "reboot" $T/calls && grep -l '^raison=avant redemarrage' $T/bulk/incidents/2*/etat.txt >/dev/null 2>&1 && ok "instantane avant le redemarrage" || ko "manquant ($(inc))"
reset; conf; mkdir -p $R/cmd; : > $R/cmd/reboot
ONCE=1 guard8 >/dev/null 2>&1; sleep 2
grep -q "reboot" $T/calls && [ "$(inc)" = 0 ] && ok "redemarrage demande par HA : pas d'instantane" || ko "reboot=$(grep -c reboot $T/calls) inc=$(inc)"

echo "W4 : 6 instantanes gardes au plus"
reset; conf; mkdir -p $T/bulk/incidents
for i in 1 2 3 4 5 6 7 8; do mkdir -p $T/bulk/incidents/2026010$((i<10?0:0))-00000$i; done
conf NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=600; touch $T/net_down
ONCE=4 guard8 >/dev/null 2>&1
[ "$(inc)" = 6 ] && [ ! -d $T/bulk/incidents/20260100-000001 ] && ok "les plus anciens retires, 6 gardes" || ko "$(inc) gardes : $(ls $T/bulk/incidents | tr '\n' ' ')"

echo "W5 : /media inutilisable -> repli sur /data, petit"
reset; conf NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=600; touch $T/net_down; : > $T/bulk/incidents   # un fichier a la place du dossier
head -c 700000 /dev/urandom | base64 > $T/bb.log
ONCE=4 guard8 >/dev/null 2>&1
[ -s $T/qp/incident/etat.txt ] && ok "instantane sur /data" || ko "pas de repli"
s=$(wc -c < $T/qp/incident/bb.log 2>/dev/null || echo 0); [ "$s" -le 32768 ] && ok "boite noire reduite a 32 Kio ($s)" || ko "taille $s"
[ ! -e $T/qp/incident/journal.log ] && ok "journal non recopie (deja sur /data)" || ko "journal recopie"

echo "W6 : mode passif -> aucun instantane"
reset; conf PASSIVE=1 NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=3; touch $T/net_down
ONCE=6 guard8 >/dev/null 2>&1
[ "$(inc)" = 0 ] && [ ! -d $T/qp/incident ] && ok "rien ecrit" || ko "ecrit en mode passif"
summary
