#!/bin/bash
# Essais a blanc des durcissements v5 de Qiara Plus (revue du 27/10/2026) : guard.conf lu sans etre execute,
# arrets par numero de processus verifies, limite horaire des ordres, verrou sans fenetre de vol.
# Banc : voir lib.sh (chroot ARM sous qemu, ou lien vers / avec dash). Rien n'est ecrit sur la camera.
. "$(dirname "$0")/lib.sh"
A=$T/qp/state; R=$T/run
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "$@" > $T/qp/guard.conf; }
guard() { run "$ENVV QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=${APPCOMM:-sleep} QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
# faux processus applicatif dont le nom (comm) est $1 : copie de sleep sous ce nom
proc_named() { cp "$(command -v sleep)" "$T/$1"; "$T/$1" 300 & PN=$!; sleep 0.4; }
# processus sans rapport (nom « sleep »)
proc_other() { sleep 300 & PO=$!; sleep 0.3; }
alive() { kill -0 "$1" 2>/dev/null; }
upt() { read -r u _ < /proc/uptime; echo ${u%%.*}; }

echo "V5-1 : guard.conf abime -> le surveillant demarre quand meme ; aucun code du fichier n'est execute"
reset; conf "REBOOT_MAX=2 3 x (" "touch /tmp/qptest/execute-par-conf" "NET_L1_SEC=7" "FOO=bar" 'ENABLE_REBOOT="0"'
ONCE=1 guard >/dev/null 2>&1
[ -s $R/guard-status ] && ok "surveillant demarre malgre le fichier abime" || ko "pas d'etat ecrit (surveillant mort au demarrage ?)"
[ ! -e $T/execute-par-conf ] && ok "ligne de commande du fichier non executee" || ko "code du fichier execute"
grep -q "guard.conf" $T/log && ok "lignes refusees journalisees" || ko "rien de journalise"

echo "V5-2 : guard.conf correct -> reglages pris en compte (valeur entre guillemets comprise)"
reset; conf NET_L1_SEC=2 NET_L2_SEC=600 NET_L3_SEC=900 'GATEWAY="192.0.2.254"' "# commentaire" ""; touch $T/net_down
ONCE=5 guard >/dev/null 2>&1
grep -q "wifi_disconnect" $T/calls && ok "NET_L1_SEC=2 applique" || ko "reglage ignore"
reset; conf PASSIVE=1 NET_L1_SEC=1 NET_L2_SEC=600 NET_L3_SEC=900; touch $T/net_down
ONCE=5 guard >/dev/null 2>&1
! grep -q "wifi_disconnect" $T/calls && grep -q "passif" $T/log && ok "PASSIVE=1 applique" || ko "mode passif ignore"

echo "V5-3 : ordre restart-app avec un numero de processus perime -> le processus sans rapport n'est pas tue"
reset; conf; proc_other; mkdir -p $A $R/cmd; echo $PO > $A/child; echo good > $A/running_slot
: > $R/cmd/restart-app
APPCOMM=openqiarad ONCE=1 guard >/dev/null 2>&1
alive $PO && ok "processus sans rapport laisse en vie" || ko "processus sans rapport tue (numero reutilise)"
[ ! -e $A/expected_stop ] && ok "pas de marque d'arret volontaire sans arret" || ko "marque posee a tort"
kill $PO 2>/dev/null; wait $PO 2>/dev/null
reset; conf; proc_named openqiarad; mkdir -p $A $R/cmd; echo $PN > $A/child; echo good > $A/running_slot; : > $R/cmd/restart-app
APPCOMM=openqiarad ONCE=1 guard >/dev/null 2>&1; sleep 1
alive $PN && ko "la vraie application n'est plus arretee" || ok "la vraie application est arretee (controle positif)"
[ -e $A/expected_stop ] && ok "arret volontaire marque" || ko "marque absente"
kill $PN 2>/dev/null; wait $PN 2>/dev/null

echo "V5-4 : qp-update rollback / use-prev avec numero perime -> processus sans rapport epargne"
upd() { run "$ENVV QP_APP_COMM=openqiarad QP_MIN_SIZE=1000000 /tmp/qptest/qp/qp-update $*" ; }
seed3() { fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
  upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null; upd stage /tmp/qptest/new.bin >/dev/null; }
reset; seed3; proc_other; echo $PO > $A/child; echo new > $A/running_slot
upd rollback "essai" >/dev/null 2>&1
alive $PO && ok "rollback : processus sans rapport laisse en vie" || ko "rollback a tue un processus sans rapport"
[ "$(cat $A/active)" = good ] && ok "rollback : retour a good enregistre" || ko "etat apres rollback"
kill $PO 2>/dev/null; wait $PO 2>/dev/null
reset; seed3; upd promote --force >/dev/null 2>&1; upd stage /tmp/qptest/new.bin >/dev/null 2>&1; proc_other; echo $PO > $A/child
upd use-prev >/dev/null 2>&1
alive $PO && ok "use-prev : processus sans rapport laisse en vie" || ko "use-prev a tue un processus sans rapport"
kill $PO 2>/dev/null; wait $PO 2>/dev/null
reset; seed3; proc_named openqiarad; echo $PN > $A/child; echo new > $A/running_slot
upd rollback "essai" >/dev/null 2>&1; sleep 0.5
alive $PN && ko "rollback n'arrete plus la vraie application" || ok "rollback arrete la vraie application (controle positif)"
kill $PN 2>/dev/null; wait $PN 2>/dev/null

echo "V5-5 : ordres Wi-Fi et relance repetes -> 6 par heure au plus"
reset; conf
for i in 1 2 3 4 5 6 7 8; do mkdir -p $R/cmd; : > $R/cmd/wifi-bounce; ONCE=1 guard >/dev/null 2>&1; done
n=$(grep -c wifi_disconnect $T/calls)
[ "$n" = 6 ] && ok "wifi-bounce : 6 executions sur 8 demandes" || ko "wifi-bounce : $n executions"
grep -q "ordre HA refuse" $T/log && ok "refus journalise" || ko "refus non journalise"
reset; conf; mkdir -p $A $R
for i in 1 2 3 4 5 6 7 8; do proc_named openqiarad; echo $PN > $A/child; echo good > $A/running_slot; mkdir -p $R/cmd; : > $R/cmd/restart-app
  APPCOMM=openqiarad ONCE=1 guard >/dev/null 2>&1; sleep 0.3
  if alive $PN; then kill $PN 2>/dev/null; echo refuse >> $T/refus; fi; wait $PN 2>/dev/null; done
[ "$(grep -c refuse $T/refus 2>/dev/null)" = 2 ] && ok "restart-app : 6 executions, 2 refus sur 8 demandes" || ko "restart-app : $(grep -c refuse $T/refus 2>/dev/null) refus"

echo "V5-6 : verrou en cours de creation (pid pas encore ecrit) -> le surveillant ne le vole pas"
reset; conf; mkdir -p $R/guard.lock; proc_other
( sleep 0.4; echo $PO > $R/guard.lock/pid ) &
ONCE=1 guard >/dev/null 2>&1
[ ! -s $R/guard-status ] && ok "second surveillant sorti sans rien faire" || ko "verrou vole, second surveillant lance"
[ "$(cat $R/guard.lock/pid 2>/dev/null)" = "$PO" ] && ok "verrou du premier intact" || ko "verrou modifie"
kill $PO 2>/dev/null; wait $PO 2>/dev/null
echo "V5-7 : meme chose pour le lanceur"
reset; mk good 'echo lance >> /tmp/qptest/args; sleep 1'; mk factory 'sleep 1'; mkdir -p $A; echo good > $A/active; mkdir -p $T/run/launch.lock; proc_other
( sleep 0.4; echo $PO > $T/run/launch.lock/pid ) &
run "$ENVV QP_STABLE_SEC=2 QP_GAP_SEC=0 QP_NO_GUARD=1 /tmp/qptest/qp-launch -web :80" >/dev/null 2>&1
[ ! -e $T/args ] && ok "second lanceur sorti sans lancer l'application" || ko "verrou du lanceur vole"
kill $PO 2>/dev/null; wait $PO 2>/dev/null
summary
