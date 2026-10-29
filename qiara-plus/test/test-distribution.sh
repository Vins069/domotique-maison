#!/bin/bash
# Essais des ajouts de la distribution OpenQIARA Claude V15 a QIARA Plus v10 : installation sans post_boot.sh (camera
# preparee par l'outil amont), guard.conf de l'installeur conserve et lu (SSH_SECOURS_PORT), ordres de redemarrage
# nommes (reboot-installation, reboot-reglage). Meme banc que test-setup.sh.
. "$(dirname "$0")/lib.sh"
FA=/tmp/fakeapp
D=$T/data; M=$T/media; Q=$D/qp; B=$M/qp; R=$T/run
ENVS="QP_DATA=/tmp/qptest/data QP_MEDIA=/tmp/qptest/media QP=/tmp/qptest/data/qp QP_BULK=/tmp/qptest/media/qp QP_RUN=/tmp/qptest/run QP_LOG=/tmp/qptest/data/openqiarad.log QP_TEST=1 QP_PORT=${PORTV:-18081} QP_TICK=1 QP_STABLE_SEC=4 QP_MAXFAIL=3 QP_NOBIN_SLEEP=2 QP_DROPBEAR=/tmp/qptest/dropbear QP_LAUNCHER=/tmp/qptest/data/openqiarad QP_SYSRQ=/tmp/qptest/sysrq QP_VERIFY_SEC=60 QP_VERIFY_STABLE=5 PATH=/tmp/qptest/stubs2:/bin:/sbin:/usr/bin:/usr/sbin"
cleanup() { for p in /proc/[0-9]*; do [ "$(readlink $p/root 2>/dev/null)" = "$ROOT" ] && kill -9 ${p#/proc/} 2>/dev/null; done; sleep 1; }
setup_dirs() {
  cleanup; rm -rf $T; mkdir -p $D/qp $M $R $T/stubs2
  cp "$1" $D/openqiarad; chmod 755 $D/openqiarad; : > $D/openqiarad.log
  for c in fbxbusctl fbxupstartctl reboot ping; do printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\nexit 0\n' > $T/stubs2/$c; chmod +x $T/stubs2/$c; done
  printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\n' > $T/dropbear; chmod +x $T/dropbear; : > $T/calls
  cp $QP_DIST/qp-setup.sh $T/qp-setup.sh
}
bootloop() { chroot $ROOT /bin/sh -c "export $ENVS; while :; do /tmp/qptest/data/openqiarad -web :${PORTV:-18081} -log /tmp/qptest/data/openqiarad.log >/dev/null 2>&1; sleep 2; done" & }
setup() { chroot $ROOT /bin/sh -c "export $ENVS; sh /tmp/qptest/qp-setup.sh $*"; }
guardonce() { chroot $ROOT /bin/sh -c "export $ENVS; QP_ONCE=1 sh /tmp/qptest/data/qp/qp-guard"; }

echo "D1 : installation sur une camera sans /data/post_boot.sh (outil amont) -> post_boot.sh cree, bloc QIARA Plus ajoute"
setup_dirs $FA/fakeapp
printf 'TICK=1\nSLOW_SEC=2\nNET_CHECK_SEC=5\nENABLE_WIFI_ACTIONS=0\nENABLE_REBOOT=0\nGATEWAY=127.0.0.1\nHEALTH_GRACE=3\nHEALTH_STALE=8\nPROMOTE_AFTER=5\nSSH_SECOURS_PORT=2222\n' > $Q/guard.conf
rm -f $D/post_boot.sh; bootloop; sleep 3
setup preflight > $T/out 2>&1; rc=$?
[ $rc = 0 ] && grep -q "post_boot.sh absent : il sera cree" $T/out && ok "controles reussis, post_boot.sh annonce comme a creer" || { ko "controles : $(grep -E 'KO|info' $T/out)"; }
setup install --yes > $T/out 2>&1; rc=$?
[ $rc = 0 ] && grep -q "installation reussie" $T/out && ok "installation reussie sans post_boot.sh prealable" || { ko "installation"; tail -15 $T/out; }
[ -f $D/post_boot.sh ] && grep -q '^# >>> qiara-plus' $D/post_boot.sh && grep -q 'qp-guard' $D/post_boot.sh && ok "post_boot.sh cree avec le bloc QIARA Plus" || ko "post_boot.sh : $(cat $D/post_boot.sh 2>&1)"
chroot $ROOT /bin/sh -n /tmp/qptest/data/post_boot.sh && ok "post_boot.sh valide" || ko "post_boot.sh invalide"
grep -q '^SSH_SECOURS_PORT=2222$' $Q/guard.conf && ok "guard.conf de l'installeur conserve" || ko "guard.conf remplace : $(cat $Q/guard.conf)"
sleep 3
grep -q "ligne ignoree (SSH_SECOURS_PORT)" $D/openqiarad.log && ko "SSH_SECOURS_PORT ignore par le surveillant" || ok "SSH_SECOURS_PORT lu par le surveillant"
i=0; while [ $i -lt 15 ] && ! grep -q 'dropbear .*-p 2222' $T/calls; do sleep 1; i=$((i+1)); done
grep -q 'dropbear .*-p 2222' $T/calls && ok "SSH de secours lance sur 2222 (port lu dans guard.conf)" || ko "SSH de secours jamais lance sur 2222 en 15 s : $(grep dropbear $T/calls | tail -2)"

echo "D2 : ordres de redemarrage nommes (fin d'installation, changement de reglage)"
cleanup; rm -rf $R/guard.lock   # verrou du surveillant arrete de force par cleanup (sur la camera, /tmp repart vide a chaque demarrage)
printf 'TICK=1\nSLOW_SEC=100\nNET_CHECK_SEC=100\nENABLE_WIFI_ACTIONS=0\nENABLE_REBOOT=1\nGATEWAY=127.0.0.1\n' > $Q/guard.conf
mkdir -p $R/cmd; : > $R/cmd/reboot-installation; : > $T/calls
guardonce >/dev/null 2>&1; sleep 2
grep -q "REDEMARRAGE de la camera : ordre HA (fin d'installation OpenQIARA Claude V15)" $D/openqiarad.log && ok "reboot-installation : raison journalisee" || ko "journal : $(grep -i redemarrage $D/openqiarad.log | tail -2)"
grep -q 'reboot' $T/calls && ok "reboot-installation : redemarrage demande" || ko "pas de reboot : $(cat $T/calls)"
rm -rf $Q/state/rate_* 2>/dev/null; : > $T/calls; : > $R/cmd/reboot-reglage
guardonce >/dev/null 2>&1; sleep 2
grep -q "ordre HA (changement de reglage video, reglage.sh)" $D/openqiarad.log && grep -q reboot $T/calls && ok "reboot-reglage : raison journalisee, redemarrage demande" || ko "reboot-reglage : $(grep -i redemarrage $D/openqiarad.log | tail -1)"
: > $R/cmd/reboot-inconnu; guardonce >/dev/null 2>&1
grep -q "ordre inconnu ignore : reboot-inconnu" $D/openqiarad.log && ok "ordre inconnu toujours ignore" || ko "ordre inconnu : $(tail -3 $D/openqiarad.log)"
cleanup; rm -rf $R/guard.lock   # verrou du surveillant arrete de force par cleanup (sur la camera, /tmp repart vide a chaque demarrage)
summary
