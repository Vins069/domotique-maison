#!/bin/bash
# Essais a blanc des ajouts v7 (chroot ARM sous qemu) : resultat de mise a jour persistant, boite noire relancee par le
# surveillant, echantillons de la detection interne liberes. Aucune ecriture sur la camera.
. "$(dirname "$0")/lib.sh"
A=$T/qp/state; R=$T/run
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "$@" > $T/qp/guard.conf; }
G7ENV="QP_BB_PID=/tmp/qptest/bb.pid QP_SAMPLES=/tmp/qptest/vision.samples QP_SAMPLES_AFTER=0"
guard7() { run "$ENVV $G7ENV QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
fakebb() { printf '#!/bin/sh\necho $$ > /tmp/qptest/bb.pid\nsleep 300\n' > $T/qp/bb.sh; }   # comme la vraie : pas d'exec
bbpid() { cat $T/bb.pid 2>/dev/null; }
nbb() { c=0; for p in /proc/[0-9]*; do [ "$(readlink $p/root 2>/dev/null)" = "$RROOT" ] && grep -q bb.sh $p/cmdline 2>/dev/null && c=$((c+1)); done; echo $c; }
killbb() { for p in /proc/[0-9]*; do [ "$(readlink $p/root 2>/dev/null)" = "$RROOT" ] && grep -q -E 'bb.sh|hlcamd|samples' $p/cmdline 2>/dev/null && kill -9 ${p#/proc/} 2>/dev/null; done; sleep 0.3; }
fakehlcamd() { # faux hlcamd (meme nom de processus), lance avec la detection interne $1
  printf '#!/bin/sh\nsleep 300\n' > $T/hlcamd; chmod +x $T/hlcamd   # le processus garde le nom hlcamd
  chroot $ROOT /tmp/qptest/hlcamd -d 75 --iv-detection 1 --1080p-bitrate 1500000 --iv-detection $1 --gop-denum 2 & sleep 0.5; }

echo "V1 : boite noire non installee -> rien n'est lance, etat bb=off"
reset; conf; killbb
ONCE=1 guard7 >/dev/null 2>&1
grep -q '^bb=off$' $R/guard-status && ok "bb=off" || ko "etat : $(grep bb= $R/guard-status)"
[ "$(nbb)" = 0 ] && ok "aucune boite noire lancee" || ko "lancee sans etre installee"
fakebb
ONCE=1 guard7 >/dev/null 2>&1
[ "$(nbb)" = 0 ] && ok "installee mais pas activee (bb.on absent) : rien" || ko "lancee sans bb.on"

echo "V2 : boite noire installee et activee -> lancee, une seule fois"
touch $T/qp/bb.on
ONCE=1 guard7 >/dev/null 2>&1; sleep 0.8
[ "$(nbb)" = 1 ] && [ -n "$(bbpid)" ] && ok "lancee (pid $(bbpid))" || ko "non lancee ($(nbb))"
grep -q "boite noire absente : lancement" $T/log && ok "lancement journalise" || ko "pas de journal"
ONCE=2 guard7 >/dev/null 2>&1; sleep 0.5
[ "$(nbb)" = 1 ] && ok "pas de seconde instance" || ko "$(nbb) instances"
grep -q '^bb=1$' $R/guard-status && ok "bb=1" || ko "etat : $(grep bb= $R/guard-status)"

echo "V3 : boite noire arretee -> relancee ; 4 lancements par heure au plus"
for i in 1 2 3 4; do killbb; ONCE=1 guard7 >/dev/null 2>&1; sleep 0.6; done
[ "$(nbb)" = 0 ] && ok "5e lancement en 1 h refuse" || ko "$(nbb) instance(s) apres 5 lancements"
grep -q '^bb=0$' $R/guard-status && ok "bb=0 (activee mais absente)" || ko "etat : $(grep bb= $R/guard-status)"
[ "$(grep -c 'boite noire absente : lancement' $T/log)" = 4 ] && ok "4 lancements journalises" || ko "$(grep -c 'boite noire absente' $T/log) lancements"
echo 999 > $T/bb.pid; rm -f $A/rate_bbstart
ONCE=1 guard7 >/dev/null 2>&1; sleep 0.6
[ "$(nbb)" = 1 ] && ok "pid perime (autre processus) : relancee" || ko "pid perime cru vivant"
killbb

echo "V4 : echantillons de la detection interne"
reset; conf; killbb; head -c 2419208 /dev/zero > $T/vision.samples
fakehlcamd 1; ONCE=2 guard7 >/dev/null 2>&1
[ -f $T/vision.samples ] && ok "detection active : echantillons gardes" || ko "retires alors que la detection est active"
killbb; fakehlcamd 0
chroot $ROOT /bin/sh -c 'exec sleep 30 < /tmp/qptest/vision.samples' & OP=$!; sleep 0.5
ONCE=2 guard7 >/dev/null 2>&1
[ -f $T/vision.samples ] && ok "fichier ouvert par un processus : garde" || ko "retire alors qu'il est ouvert"
kill $OP 2>/dev/null; wait $OP 2>/dev/null
ONCE=2 guard7 >/dev/null 2>&1
[ ! -f $T/vision.samples ] && ok "detection coupee, fichier libre : retire" || ko "non retire"
grep -q "vision.samples retire (2362 Kio" $T/log && ok "retrait journalise avec la taille" || ko "journal : $(grep samples $T/log)"
grep -q '^video_iv=0$' $R/guard-status && ok "video_iv=0 releve" || ko "$(grep video_iv $R/guard-status)"
killbb

echo "V5 : resultat de mise a jour conserve sur la carte"
reset; conf; fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null; upd stage /tmp/qptest/new.bin >/dev/null
grep -q '^essai en cours' $R/last_update_result && grep -q '^essai en cours' $A/last_update_result && ok "ecrit en memoire et sur la carte" || ko "$(cat $R/last_update_result) / $(cat $A/last_update_result 2>&1)"
rm -rf $R; mkdir -p $R                                         # redemarrage : la memoire vive est vide
upd status | grep -q '^last_result=essai en cours' && ok "apres redemarrage : qp-update status le lit sur la carte" || ko "status : $(upd status | grep last_result)"
ONCE=1 guard7 >/dev/null 2>&1
grep -q '^update_result=essai en cours' $R/guard-status && ok "apres redemarrage : le surveillant le publie" || ko "guard-status : $(grep update_result $R/guard-status)"
upd rollback test >/dev/null
grep -q '^annule: retour a good (test)' $A/last_update_result && ok "retour arriere conserve" || ko "$(cat $A/last_update_result)"
rm -f $A/last_update_result $R/last_update_result; ONCE=1 guard7 >/dev/null 2>&1
grep -q '^update_result=aucun$' $R/guard-status && ok "aucun resultat : « aucun »" || ko "$(grep update_result $R/guard-status)"

echo "V6 : ancien guard.conf avec ENABLE_SOC_WDT=1 -> aucun chien de garde materiel"
reset; conf ENABLE_SOC_WDT=1
ONCE=1 guard7 >/dev/null 2>&1
! grep -q 'chien de garde' $T/log && ! grep -q watchdog $QP_DIST/qp-guard && ok "aucun chien de garde arme" || ko "chien de garde"
[ -s $R/guard-status ] && ok "surveillant fonctionnel" || ko "surveillant en echec"

summary
