#!/bin/bash
# Essais a blanc du surveillant v2 (chroot ARM sous qemu). Aucune ecriture sur la camera.
. "$(dirname "$0")/lib.sh"
A=$T/qp/state; R=$T/run
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "SSH_SECOURS_PORT=2222" "$@" > $T/qp/guard.conf; }
upt() { read -r u _ < /proc/uptime; echo ${u%%.*}; }
bid() { cat /proc/sys/kernel/random/boot_id; }
fakechild() { # faux processus applicatif enregistre comme lance par le lanceur, demarre il y a $1 s
  mkdir -p $A $R; chroot $ROOT /bin/sleep 300 & CH=$!; sleep 0.5
  echo $CH > $A/child; echo ${2:-good} > $A/running_slot; echo $(( $(upt) - ${1:-400} )) > $A/run_up; bid > $A/run_boot
}
killchild() { kill $CH 2>/dev/null; wait $CH 2>/dev/null; }
health() { printf 'ts=%s\nup=%s\nmqtt=%s\napp_ok=%s\n' "$(date +%s)" "$(( $(upt) - ${3:-0} ))" "${1:-1}" "${2:-1}" > $R/health; }
seed3() { fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
  upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null; upd stage /tmp/qptest/new.bin >/dev/null; }

echo "G1 : application figee (sante vieille selon l'uptime) -> arret force"
reset; conf HEALTH_GRACE=1 HEALTH_STALE=5; fakechild 400; health 1 1 100
ONCE=1 guard >/dev/null 2>&1; sleep 1
kill -0 $CH 2>/dev/null && ko "application figee non arretee" || ok "application figee arretee"
grep -q "application figee" $T/log && ok "journalise avec la raison" || ko "pas de journal"
killchild

echo "G2 : application saine -> rien ; horloge murale qui saute -> rien (uptime fait foi)"
reset; conf HEALTH_GRACE=1 HEALTH_STALE=5; fakechild 400
printf 'ts=5\nup=%s\nmqtt=1\napp_ok=1\n' "$(upt)" > $R/health      # horloge de l'application encore en 1970
ONCE=2 guard >/dev/null 2>&1
kill -0 $CH 2>/dev/null && ok "application saine laissee tranquille malgre l'horloge en 1970" || ko "arret a tort"
killchild

echo "G3 : periode de grace apres le lancement"
reset; conf HEALTH_GRACE=300 HEALTH_STALE=5; fakechild 10; health 1 1 100
ONCE=1 guard >/dev/null 2>&1
kill -0 $CH 2>/dev/null && ok "pas d'arret pendant la grace" || ko "arret pendant la grace"
killchild

echo "G4 : essai sain -> promotion"
reset; seed3; conf PROMOTE_AFTER=1; fakechild 400 new; health 1 1
ONCE=1 guard >/dev/null 2>&1
[ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "essai promu" || ko "essai non promu"
[ "$(sha256sum $T/bulk/slots/good/openqiarad | cut -d' ' -f1)" = "$(sha256sum $T/new.bin | cut -d' ' -f1)" ] && ok "good = nouveau" || ko "good inchange"
killchild

echo "G5 : essai dont l'application n'est pas saine -> pas de promotion"
reset; seed3; conf PROMOTE_AFTER=1; fakechild 400 new; health 1 0
ONCE=1 guard >/dev/null 2>&1
[ -e $A/trial ] && [ "$(cat $A/active)" = new ] && ok "pas de promotion si app_ok=0" || ko "promotion indue"
killchild

echo "G6 : essai fige -> retour arriere automatique"
reset; seed3; conf HEALTH_GRACE=1 HEALTH_STALE=5 TRIAL_HANG_MAX=1; fakechild 400 new; health 1 1 100
ONCE=1 guard >/dev/null 2>&1
[ -e $T/bulk/slots/new/BAD ] && [ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "retour arriere apres blocage pendant l'essai" || ko "pas de retour arriere"
killchild

echo "G7 : escalade reseau (passerelle muette)"
reset; conf NET_L1_SEC=2 NET_L2_SEC=60 NET_L3_SEC=120 REBOOT_MAX=1; touch $T/net_down   # seuils 2 et 3 hors de portee : un tour dure plus d'une seconde sous emulation
ONCE=4 guard >/dev/null 2>&1
grep -q "wifi_disconnect" $T/calls && ok "niveau 1 : reassociation" || ko "niveau 1 absent"
! grep -q "restart hlconnman" $T/calls && ok "niveau 2 pas encore" || ko "niveau 2 trop tot"
reset; conf NET_L1_SEC=2 NET_L2_SEC=5 NET_L3_SEC=60 REBOOT_MAX=1; touch $T/net_down   # v4 : l'instantane du niveau 2 prend du temps sous qemu
ONCE=7 guard >/dev/null 2>&1
grep -q "restart hlconnman" $T/calls && ok "niveau 2 : pilote Wi-Fi recharge" || ko "niveau 2 absent"
! grep -q "reboot" $T/calls && ok "pas de redemarrage avant le niveau 3" || ko "redemarrage trop tot"
reset; conf NET_L1_SEC=2 NET_L2_SEC=5 NET_L3_SEC=8 REBOOT_MAX=1; touch $T/net_down
ONCE=11 guard >/dev/null 2>&1; sleep 2
grep -q "reboot" $T/calls && grep -q "REDEMARRAGE" $T/log && ok "niveau 3 : redemarrage demande et journalise" || ko "niveau 3 absent"

echo "G8 : limite de redemarrages (REBOOT_MAX=1)"
: > $T/calls; ONCE=11 guard >/dev/null 2>&1; sleep 2
! grep -q "reboot" $T/calls && grep -q "redemarrage refuse" $T/log && ok "second redemarrage refuse" || ko "limite non appliquee"

echo "G9 : coupure breve -> aucune action"
reset; conf NET_L1_SEC=4 NET_L2_SEC=8 NET_L3_SEC=20; touch $T/net_down
ONCE=2 guard >/dev/null 2>&1; rm -f $T/net_down; ONCE=3 guard >/dev/null 2>&1
! grep -q "wifi_disconnect" $T/calls && ok "pas d'action pour une coupure breve" || ko "action sur coupure breve"

echo "G10 : ordres de Home Assistant"
reset; conf; mkdir -p $R/cmd; : > $R/cmd/wifi-bounce; : > $R/cmd/wifi-driver; : > $R/cmd/inconnu
ONCE=1 guard >/dev/null 2>&1
grep -q "wifi_disconnect" $T/calls && grep -q "restart hlconnman" $T/calls && ok "wifi-bounce et wifi-driver executes" || ko "ordres Wi-Fi"
grep -q "ordre inconnu ignore : inconnu" $T/log && ok "ordre inconnu ignore" || ko "ordre inconnu non signale"
[ -z "$(ls $R/cmd)" ] && ok "fichiers d'ordre consommes" || ko "ordres restes"
reset; conf; fakechild 400; mkdir -p $R/cmd; : > $R/cmd/restart-app
ONCE=1 guard >/dev/null 2>&1; sleep 1
! kill -0 $CH 2>/dev/null && [ -e $A/expected_stop ] && ok "restart-app : arret volontaire marque (non compte comme plantage)" || ko "restart-app"
killchild

echo "G11 : SSH manquant -> relance (lecture de /proc/net/tcp)"
reset; conf; printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n' > $T/net_tcp
ONCE=1 guard >/dev/null 2>&1
grep -q "dropbear -s -g -p 2222" $T/calls && ok "dropbear 2222 relance" || ko "dropbear 2222 non relance"
printf '  sl  local_address rem_address   st\n   1: 00000000:08AE 00000000:0000 0A 0\n   2: 4301A8C0:0016 6C01A8C0:D431 01 0\n' > $T/net_tcp; : > $T/calls
ONCE=1 guard >/dev/null 2>&1
grep -q "start dropbear" $T/calls && ok "dropbear 22 relance (une connexion etablie n'est pas une ecoute)" || ko "dropbear 22 non relance"

echo "G12 : memoire basse prolongee -> relance de l'application"
reset; conf MEM_MIN_KB=999999999 MEM_LOW_SEC=1; fakechild 400; health
ONCE=3 guard >/dev/null 2>&1; sleep 1
kill -0 $CH 2>/dev/null && ko "application non relancee" || ok "application relancee (memoire basse)"
killchild

echo "G13 : application absente trop longtemps -> lancee par le surveillant"
reset; conf DEAD_SEC=2; mkdir -p $A; printf '#!/bin/sh\necho lance >> /tmp/qptest/launched\n' > $T/launcher; chmod +x $T/launcher
run "$ENVV QP_LAUNCHER=/tmp/qptest/launcher QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=5 /tmp/qptest/qp-guard" >/dev/null 2>&1; sleep 1
[ -s $T/launched ] && ok "lanceur appele par le surveillant" || ko "lanceur non appele"

echo "G14 : pid reutilise par un autre programme -> application consideree absente"
reset; conf DEAD_SEC=1; mkdir -p $A; chroot $ROOT /bin/sleep 30 & P=$!; sleep 0.5; echo $P > $A/child
printf '#!/bin/sh\necho lance >> /tmp/qptest/launched\n' > $T/launcher; chmod +x $T/launcher
run "$ENVV QP_LAUNCHER=/tmp/qptest/launcher QP_APP_COMM=openqiarad QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=4 /tmp/qptest/qp-guard" >/dev/null 2>&1; sleep 1
[ -s $T/launched ] && ok "nom du processus verifie (pas de faux vivant)" || ko "faux vivant"
kill $P 2>/dev/null; wait $P 2>/dev/null

echo "G15 : un seul surveillant"
reset; conf; mkdir -p $R/guard.lock; ( chroot $ROOT /bin/sleep 20 ) & P=$!; sleep 0.5; echo $P > $R/guard.lock/pid
ONCE=1 guard >/dev/null 2>&1; grep -q "surveillant demarre" $T/log && ko "second surveillant lance" || ok "second surveillant refuse"
kill $P 2>/dev/null; wait $P 2>/dev/null

echo "G16 : diagnostic des reglages video de hlcamd"
reset; conf; printf '#!/bin/sh\nsleep 30\n' > $T/hlcamd; chmod +x $T/hlcamd
chroot $ROOT /tmp/qptest/hlcamd -d 75 --iv-detection 1 --use-h264 --1080p-bitrate 4000000 --iv-detection 0 --gop-denum 2 & P=$!; sleep 1
ONCE=1 guard >/dev/null 2>&1
grep -q '^video_iv=0' $R/guard-status && grep -q '^video_bitrate=4000000' $R/guard-status && grep -q '^video_gop_denum=2' $R/guard-status && ok "reglages effectifs lus (derniere valeur retenue)" || { ko "lecture des reglages"; grep video $R/guard-status; }
kill $P 2>/dev/null; wait $P 2>/dev/null

echo "G17 : fichier d'etat complet"
grep -q '^net_ok=1' $R/guard-status && grep -q '^slot=' $R/guard-status && grep -q '^mem_avail_kb=[0-9]' $R/guard-status && grep -q '^ssh22=1' $R/guard-status && ok "guard-status complet" || { ko "guard-status incomplet"; cat $R/guard-status; }

echo "G18 : sobriete : en regime etabli, seul 'sleep' est lance a chaque tour (strace)"
reset; conf SLOW_SEC=3600 NET_CHECK_SEC=3600; fakechild 400; health
strace -f -qq -e trace=execve -o $T/../st.txt chroot $ROOT /bin/sh -c "$ENVV QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_DROPBEAR=/tmp/qptest/dropbear QP_ONCE=11 /tmp/qptest/qp-guard" >/dev/null 2>&1
ns=$(grep 'execve(' $T/../st.txt | grep -c '"/bin/sleep"'); no=$(grep 'execve(' $T/../st.txt | grep -v qemu-arm | grep -vc '"/bin/sleep"')
echo "        11 tours : $ns sleep, $no autres programmes (demarrage compris)"
[ "$ns" -le 11 ] && [ "$no" -le 14 ] && ok "1 seul programme externe par tour (sleep), le reste en commandes internes" || ko "trop de programmes ($ns sleep, $no autres)"
killchild
echo "G19 : mode passif (essai a blanc) : aucune action, seulement le journal"
reset; conf PASSIVE=1 NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=3 HEALTH_GRACE=1 HEALTH_STALE=5 DEAD_SEC=1; touch $T/net_down
printf '  sl  local_address rem_address   st\n' > $T/net_tcp
fakechild 400; health 1 1 100; mkdir -p $R/cmd; : > $R/cmd/reboot
ONCE=6 guard >/dev/null 2>&1; sleep 2
kill -0 $CH 2>/dev/null && [ ! -s $T/calls ] && ok "aucune action (application intacte, aucune commande systeme)" || { ko "action en mode passif"; cat $T/calls; }
grep -q "(passif, non fait)" $T/log && ok "les actions evitees sont journalisees" || ko "pas de journal passif"
killchild
summary
