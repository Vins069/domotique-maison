#!/bin/bash
# Essais a blanc de bout en bout : installation, mise a jour, plantage, blocage, coupure, retrait, echec d'installation.
. "$(dirname "$0")/lib.sh"
FA=/tmp/fakeapp
D=$T/data; M=$T/media; Q=$D/qp; B=$M/qp; R=$T/run
ENVS="QP_DATA=/tmp/qptest/data QP_MEDIA=/tmp/qptest/media QP=/tmp/qptest/data/qp QP_BULK=/tmp/qptest/media/qp QP_RUN=/tmp/qptest/run QP_LOG=/tmp/qptest/data/openqiarad.log QP_TEST=1 QP_PORT=${PORTV:-18080} QP_TICK=1 QP_STABLE_SEC=4 QP_MAXFAIL=3 QP_NOBIN_SLEEP=2 QP_DROPBEAR=/tmp/qptest/dropbear QP_LAUNCHER=/tmp/qptest/data/openqiarad QP_SYSRQ=/tmp/qptest/sysrq QP_VERIFY_SEC=60 QP_VERIFY_STABLE=5 PATH=/tmp/qptest/stubs2:/bin:/sbin:/usr/bin:/usr/sbin"
cleanup() { for p in /proc/[0-9]*; do [ "$(readlink $p/root 2>/dev/null)" = "$ROOT" ] && kill -9 ${p#/proc/} 2>/dev/null; done; sleep 1; }
setup_dirs() { # setup_dirs binaire_courant binaire_origine
  cleanup; rm -rf $T; rm -f $ROOT/media/openqiarad.old $ROOT/media/openqiarad.old.sha256; mkdir -p $D/qp $M $R $T/stubs2
  cp "$1" $D/openqiarad; chmod 755 $D/openqiarad; cp "$2" $M/openqiarad.old; chmod 755 $M/openqiarad.old
  printf '# post_boot de test\necho post_boot\n' > $D/post_boot.sh; : > $D/openqiarad.log
  for c in fbxbusctl fbxupstartctl reboot ping; do printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\nexit 0\n' > $T/stubs2/$c; chmod +x $T/stubs2/$c; done
  printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\n' > $T/dropbear; chmod +x $T/dropbear; : > $T/calls
  printf 'TICK=1\nSLOW_SEC=2\nNET_CHECK_SEC=5\nENABLE_WIFI_ACTIONS=0\nENABLE_REBOOT=0\nENABLE_SOC_WDT=0\nGATEWAY=127.0.0.1\nHEALTH_GRACE=3\nHEALTH_STALE=8\nPROMOTE_AFTER=5\nTRIAL_HANG_MAX=2\n' > $D/qp/guard.conf
  cp $QP_DIST/qp-setup.sh $T/qp-setup.sh
}
bootloop() { # reproduit la boucle de boot.sh
  chroot $ROOT /bin/sh -c "export $ENVS; while :; do /tmp/qptest/data/openqiarad -web :18080 -log /tmp/qptest/data/openqiarad.log >/dev/null 2>&1; echo '[boot] sorti' >> /tmp/qptest/data/openqiarad.log; sleep 2; done" &
  BL=$!
}
setup() { chroot $ROOT /bin/sh -c "export $ENVS; sh /tmp/qptest/qp-setup.sh $*"; }
waitfor() { for i in $(seq 1 $1); do eval "$2" && return 0; sleep 1; done; return 1; }
slotrun() { cat $Q/state/running_slot 2>/dev/null; }
shaof() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
sh_stage() { chroot $ROOT /bin/sh -c "export $ENVS; sh /tmp/qptest/data/qp/qp-update stage $1 $2"; }
restart_app() { chroot $ROOT /bin/sh -c "kill \$(cat /tmp/qptest/data/qp/state/child)"; }

echo "S1 : essai a blanc en memoire vive (sur le vrai shell de la camera)"
setup_dirs $FA/fakeapp $FA/fakeapp-v0
setup selftest > $T/out 2>&1; rc=$?
[ $rc = 0 ] && grep -q "essai a blanc reussi" $T/out && ok "selftest reussi" || { ko "selftest"; cat $T/out; }
[ ! -e $D/qp/qp-guard ] && [ ! -e $B ] && ok "selftest n'a rien ecrit dans /data ni /media" || ko "selftest a ecrit"

echo "S1b : essai a blanc avec /tmp monte sans droit d'execution (noexec), comme sur la camera"
if [ "$RROOT" = / ]; then echo "  saute : le banc est la racine reelle (lien vers /) ; ce controle monte un tmpfs sur \$ROOT/tmp et masquerait le vrai /tmp"; else
NOEXEC_TMP=$(mktemp -d); cp $QP_DIST/qp-setup.sh $NOEXEC_TMP/qp-setup-noexec.sh
mount -t tmpfs -o noexec,size=16m tmpfs $ROOT/tmp && cp $NOEXEC_TMP/qp-setup-noexec.sh $ROOT/tmp/qp-setup.sh
chroot $ROOT /bin/sh -c 'cd /tmp && sh /tmp/qp-setup.sh selftest' > $NOEXEC_TMP/noexec.out 2>&1; rc=$?
umount $ROOT/tmp
[ $rc = 0 ] && grep -q "essai a blanc reussi" $NOEXEC_TMP/noexec.out && ok "selftest reussi malgre /tmp noexec" || { ko "selftest sous noexec"; cat $NOEXEC_TMP/noexec.out; }
fi

echo "S2 : controles en lecture seule"
setup_dirs $FA/fakeapp $FA/fakeapp-v0; bootloop; sleep 2
before=$(find $D $M -type f | sort | xargs sha256sum 2>/dev/null | sha256sum)
setup preflight > $T/out 2>&1; rc=$?
after=$(find $D $M -type f | sort | xargs sha256sum 2>/dev/null | sha256sum)
[ $rc = 0 ] && ok "controles reussis" || { ko "controles"; cat $T/out; }
[ "$before" = "$after" ] && ok "controles : aucune ecriture" || ko "controles ont ecrit"

echo "S3 : installation"
setup install --yes > $T/out 2>&1; rc=$?
[ $rc = 0 ] && grep -q "installation reussie" $T/out && ok "installation reussie" || { ko "installation"; cat $T/out; tail -20 $D/openqiarad.log; }
head -c2 $D/openqiarad | grep -q '#!' && ok "lanceur en place" || ko "lanceur absent"
[ "$(shaof $B/slots/good/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ok "good = ancien binaire courant (identique)" || ko "good different"
[ "$(shaof $Q/slots/factory/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ok "factory = binaire en service avant l'installation (identique)" || ko "factory different"
[ "$(stat -c %h $Q/slots/factory/openqiarad)" -ge 1 ] && [ ! -e $Q/slots/factory/openqiarad.part ] && ok "factory sans fichier partiel" || ko "factory partiel"
grep -q "qiara-plus" $D/post_boot.sh && ls $D/post_boot.sh.avant-qp-* >/dev/null 2>&1 && ok "post_boot.sh complete, copie conservee" || ko "post_boot.sh"
sh -n $D/post_boot.sh && ok "post_boot.sh valide" || ko "post_boot.sh invalide"
grep -q '^GOGC=75$' $Q/app.env && grep -q '^GOMEMLIMIT=32MiB$' $Q/app.env && ok "reglages memoire Go poses (app.env)" || ko "app.env absent"
[ "$(slotrun)" = good ] && ok "application lancee par le lanceur (good)" || ko "application non lancee ($(slotrun))"
[ -s $R/guard-status ] && ok "surveillant actif" || ko "surveillant absent"
[ "$(shaof $M/openqiarad.old)" = "$(shaof $FA/fakeapp)" ] && grep -q "^$(shaof $FA/fakeapp)  openqiarad.old" $M/openqiarad.old.sha256 && ok "copie de secours (QP_MEDIA) mise a jour avec son empreinte" || ko "copie de secours non mise a jour sous QP_MEDIA"
[ ! -e $ROOT/media/openqiarad.old ] && [ ! -e $ROOT/media/openqiarad.old.sha256 ] && ok "rien d'ecrit dans le vrai /media (QP_OLD suit QP_MEDIA)" || ko "ecriture dans le vrai /media"
g1=$(cat $R/guard.lock/pid 2>/dev/null)
printf '\n# lanceur modifie (essai de reinstallation)\n' >> $D/openqiarad
setup install --yes > $T/out2 2>&1; [ $? = 0 ] && ok "reinstallation idempotente" || { ko "reinstallation"; cat $T/out2; }
[ "$(shaof $D/openqiarad)" = "$(shaof $QP_DIST/qp-launch)" ] && ok "reinstallation : lanceur remplace par la version livree" || ko "lanceur non mis a jour"
g2=$(cat $R/guard.lock/pid 2>/dev/null); [ -n "$g2" ] && [ "$g2" != "$g1" ] && ! kill -0 "$g1" 2>/dev/null && ok "reinstallation : ancien surveillant arrete, nouveau en place" || ko "surveillant non renouvele ($g1 -> $g2)"
[ "$(shaof $Q/slots/factory/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ok "reinstallation : factory conserve" || ko "factory remplace a la reinstallation"
[ "$(grep -c 'qiara-plus (ne pas' $D/post_boot.sh)" = 1 ] && ok "un seul bloc dans post_boot.sh" || ko "bloc duplique"

echo "S4 : mise a jour saine -> essai -> promotion automatique"
cp $FA/fakeapp-v2 $T/v2.bin
sh_stage /tmp/qptest/v2.bin $(shaof $FA/fakeapp-v2) > $T/out 2>&1; [ $? = 0 ] && ok "stage accepte" || { ko "stage"; cat $T/out; }
restart_app
waitfor 20 '[ "$(slotrun)" = new ]' && ok "l'application demarre sur new" || ko "new non lance"
waitfor 40 '[ "$(shaof $B/slots/good/openqiarad)" = "$(shaof $FA/fakeapp-v2)" ]' && ok "essai valide : good = nouvelle version" || { ko "pas de promotion"; tail -8 $D/openqiarad.log; }
waitfor 5 '[ ! -e $Q/state/trial ] && [ "$(cat $Q/state/active)" = good ]' && ok "essai clos, actif = good" || ko "etat apres promotion"
[ "$(shaof $Q/slots/factory/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ok "factory intact" || ko "factory touche"

echo "S5 : mise a jour qui plante au demarrage -> retour automatique"
cp $FA/fakeapp-crash $T/crash.bin; head -c 300 /dev/urandom >> $T/crash.bin
sh_stage /tmp/qptest/crash.bin > $T/out 2>&1
restart_app
waitfor 60 '[ -e $B/slots/new/BAD ] && [ "$(slotrun)" = good ]' && ok "new ecarte (BAD), good relance" || { ko "pas de retour arriere"; tail -12 $D/openqiarad.log; }
[ "$(shaof $B/slots/good/openqiarad)" = "$(shaof $FA/fakeapp-v2)" ] && ok "good inchange" || ko "good modifie"
grep -q "echec" $R/last_update_result && ok "echec consigne pour Home Assistant" || ko "echec non consigne ($(cat $R/last_update_result))"

echo "S6 : mise a jour qui se fige -> retour automatique"
cp $FA/fakeapp-hang $T/hang.bin; head -c 301 /dev/urandom >> $T/hang.bin
sh_stage /tmp/qptest/hang.bin > $T/out 2>&1
restart_app
waitfor 10 '[ "$(slotrun)" = new ]'
waitfor 120 '[ -e $B/slots/new/BAD ] && [ "$(slotrun)" = good ]' && ok "blocage detecte, new ecarte, good relance" || { ko "blocage non traite"; tail -15 $D/openqiarad.log; }

echo "S7 : coupure du courant en pleine mise a jour (fichier partiel) puis demarrage"
cleanup
head -c 900000 $FA/fakeapp-v2 > $B/slots/new/openqiarad.part; rm -f $B/slots/new/openqiarad $B/slots/new/openqiarad.sha256
printf '%s\n' new > $Q/state/active; touch $Q/state/trial
bootloop; waitfor 20 '[ "$(slotrun)" = good ]' && ok "demarrage normal sur good malgre le fichier partiel" || { ko "demarrage"; tail $D/openqiarad.log; }

echo "S8 : retrait"
setup uninstall --yes > $T/out 2>&1; rc=$?
[ $rc = 0 ] && ok "retrait termine" || { ko "retrait"; cat $T/out; }
! head -c2 $D/openqiarad | grep -q '#!' && ok "binaire reel de retour sous /data/openqiarad" || ko "lanceur reste"
[ "$(shaof $D/openqiarad)" = "$(shaof $FA/fakeapp-v2)" ] && ok "binaire restaure = derniere version validee" || ko "binaire restaure different"
! grep -q "qiara-plus" $D/post_boot.sh && ok "bloc retire de post_boot.sh" || ko "bloc reste"
waitfor 20 'grep -lx openqiarad /proc/[0-9]*/comm >/dev/null 2>&1' && ok "l'application tourne de nouveau (sans lanceur)" || ko "application absente"
[ ! -e $Q ] && [ ! -e $B ] && ok "fichiers de Qiara Plus retires (/data/qp, /media/qp)" || ko "fichiers de Qiara Plus restes"
cleanup

echo "S9 : echec du controle apres bascule -> retour arriere automatique"
setup_dirs $FA/fakeapp $FA/fakeapp-v0
bootloop; sleep 2
PORTV=18081
ENVS=${ENVS/QP_PORT=18080/QP_PORT=18081}
setup install --yes > $T/out 2>&1; rc=$?
[ $rc != 0 ] && grep -q "retour arriere automatique" $T/out && ok "echec detecte, retour arriere" || { ko "pas de retour arriere"; tail -15 $T/out; }
! head -c2 $D/openqiarad | grep -q '#!' && ! grep -q "qiara-plus" $D/post_boot.sh && ok "etat d'origine retabli (binaire, post_boot)" || ko "etat non retabli"
[ "$(shaof $D/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ok "binaire d'origine identique" || ko "binaire different"
[ ! -e $Q/qp-guard ] && [ ! -e $B ] && ok "aucun reste de Qiara Plus apres le retour arriere" || ko "restes apres retour arriere"
cleanup
PORTV=18080; ENVS=${ENVS/QP_PORT=18081/QP_PORT=18080}

echo "S10 : echec avant la bascule (ecriture de post_boot.sh impossible) -> tout est retire, rien n'a change"
setup_dirs $FA/fakeapp $FA/fakeapp-v0
bootloop; sleep 2
mkdir -p "$D/post_boot.sh.qp.tmp/bloque"
setup install --yes > $T/out 2>&1; rc=$?
[ $rc != 0 ] && grep -q "ecriture de post_boot.sh impossible" $T/out && ok "echec signale" || { ko "echec non signale"; tail -8 $T/out; }
[ ! -e $Q/qp-guard ] && [ ! -e $Q/slots ] && [ ! -e $B ] && ok "fichiers partiels retires" || ko "fichiers partiels restes"
[ "$(shaof $D/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ! grep -q "qiara-plus" $D/post_boot.sh && ok "binaire et post_boot.sh inchanges" || ko "etat modifie"
[ ! -e /tmp/camroot/tmp/qp-install.lock ] && ok "verrou d'installation libere" || ko "verrou reste"
cleanup

echo "S11 : deux installations simultanees -> la seconde est refusee"
setup_dirs $FA/fakeapp $FA/fakeapp-v0
mkdir -p $ROOT/tmp/qp-install.lock
setup install --yes > $T/out 2>&1; rc=$?
[ $rc != 0 ] && grep -q "deja en cours" $T/out && [ ! -e $Q/qp-guard ] && ok "seconde installation refusee sans rien ecrire" || { ko "seconde installation non refusee"; tail -5 $T/out; }
rmdir $ROOT/tmp/qp-install.lock
cleanup
summary
