#!/bin/bash
# Essais a blanc du lanceur v2 (exec) sur le vrai shell de la camera (chroot ARM sous qemu). Aucune ecriture sur la camera.
. "$(dirname "$0")/lib.sh"
S=$T/bulk/slots; A=$T/qp/state
st() { mkdir -p $A; echo "$1" > $A/active; }

echo "L1 : good sain, lancement normal, arguments, remplacement du lanceur (meme pid)"
reset; mk good 'echo "args=$* pid=$$" >> /tmp/qptest/args; sleep 2'; mk factory 'sleep 3'; st good
launch
grep -q "demarrage de good" $T/log && ok "good lance" || ko "good non lance"
grep -q -- "args=-web :80 -log /x" $T/args && ok "arguments transmis" || ko "arguments perdus"
p=$(sed -n 's/.*pid=//p' $T/args); [ "$p" = "$(cat $A/child)" ] && [ "$p" = "$(cat $T/run/launch.lock/pid)" ] && ok "l'application a pris le pid du lanceur (exec : aucun processus en plus)" || ko "pid different ($p / $(cat $A/child))"
[ "$(cat $A/running_slot)" = good ] && [ -s $A/run_up ] && [ -s $A/run_boot ] && ok "etat du lancement enregistre (uptime, boot_id)" || ko "etat incomplet"

echo "L2 : new plante -> 3 arrets rapides comptes -> BAD -> retour a good"
reset; mk new 'exit 1'; mk good 'sleep 3'; mk factory 'sleep 3'; st new; touch $A/trial
for i in 1 2 3; do launch; done
[ ! -e $S/new/BAD ] && ok "pas encore BAD apres 2 arrets comptes" || ko "BAD trop tot"
launch
[ -e $S/new/BAD ] && ok "new marque BAD au 3e arret rapide" || ko "new non marque BAD"
[ ! -e $A/trial ] && grep -q "echec" $T/run/last_update_result && ok "essai clos, resultat consigne" || ko "essai non clos"
tail -1 $T/log | grep -q "demarrage de good" && [ "$(cat $A/active)" = good ] && ok "relance immediate sur good" || ko "pas de repli sur good"

echo "L3 : binaire corrompu (empreinte differente) -> suivant"
reset; mk good 'sleep 3'; mk factory 'sleep 3'; st good
echo "# corruption" >> $S/good/openqiarad
launch
grep -q "demarrage de factory" $T/log && ok "repli sur factory" || ko "pas de repli"

echo "L4 : good sans fichier d'empreinte refuse (ecriture interrompue)"
reset; mk good 'sleep 3'; mk factory 'sleep 3'; st good; rm -f $S/good/openqiarad.sha256
launch
grep -q "demarrage de factory" $T/log && ok "good sans empreinte refuse" || ko "good sans empreinte accepte"

echo "L5 : aucun emplacement, copie /media/openqiarad.old"
reset; mkdir -p $ROOT/media; rm -f $ROOT/media/openqiarad.old.sha256; printf '#!/bin/sh\nsleep 3\n' > $ROOT/media/openqiarad.old; chmod +x $ROOT/media/openqiarad.old
launch
grep -q "repli sur /media/openqiarad.old" $T/log && ok "repli sur la copie /media" || ko "repli /media absent"
rm -f $ROOT/media/openqiarad.old $ROOT/media/openqiarad.old.sha256

echo "L6 : rien du tout -> sortie 1, verrou libere, pas de boucle folle"
reset
launch; rc=$?
[ $rc = 1 ] && grep -q "AUCUN binaire" $T/log && [ ! -e $T/run/launch.lock ] && ok "sortie 1 + message + verrou libere" || ko "comportement sans binaire"

echo "L7 : factory n'est jamais ecarte"
reset; mk factory 'exit 1'; st factory
for i in 1 2 3 4 5; do launch; done
[ ! -e $T/qp/slots/factory/BAD ] && ok "factory jamais BAD" || ko "factory marque BAD"

echo "L8 : le marquage BAD expire (meme demarrage, ancien format, autre demarrage) ; repli temporaire sans changer l'emplacement actif"
reset; mk good 'sleep 3'; mk prev 'sleep 3'; st good
read -r U _ < /proc/uptime; U=${U%%.*}; B=$(cat /proc/sys/kernel/random/boot_id)
echo "$B $(( U - 100 )) 0" > $S/good/BAD; QP_BAD_TTL=60 launch
grep -q "demarrage de good" $T/log && ok "BAD expire (meme demarrage, uptime)" || ko "BAD n'expire pas (uptime)"
: > $T/log; echo $(( $(date +%s) - 5000 )) > $S/good/BAD; launch
grep -q "demarrage de good" $T/log && ok "BAD expire (ancien format)" || ko "BAD ancien format"
: > $T/log; echo "autre-boot 10 $(( $(date +%s) - 100 ))" > $S/good/BAD; launch
grep -q "demarrage de prev" $T/log && ok "BAD recent d'un autre demarrage conserve (repli sur prev)" || ko "BAD perdu au redemarrage"
[ "$(cat $A/active)" = good ] && ok "repli temporaire : l'emplacement actif reste good" || ko "emplacement actif change ($(cat $A/active))"
: > $T/log; echo "autre-boot 10 5" > $S/good/BAD; launch
grep -q "demarrage de prev" $T/log && ok "horloge non plausible : BAD conserve par prudence" || ko "BAD expire sur horloge douteuse"
: > $T/log; rm -f $S/good/BAD; launch
grep -q "demarrage de good" $T/log && ok "good retente des que le marquage a disparu" || ko "good non retente"
echo "L8b : essai inutilisable (empreinte fausse) -> essai termine, retour durable a good"
reset; mk new 'sleep 3'; mk good 'sleep 3'; st new; touch $A/trial; echo 0000 > $S/new/openqiarad.sha256
launch
grep -q "demarrage de good" $T/log && [ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "essai termine, active=good" || ko "essai non termine ($(cat $A/active))"
grep -q "echec" $T/run/last_update_result 2>/dev/null && ok "resultat de mise a jour : echec signale" || ko "resultat non signale"
echo "L8c : la sante d'un lancement precedent est effacee"
reset; mk good 'sleep 3'; st good; echo "ts=1 up=5" > $T/run/health
launch
[ ! -e $T/run/health ] && ok "fichier de sante efface au lancement" || ko "sante perimee conservee"

echo "L9 : boucle de redemarrages de la camera (new jamais valide) -> new ecarte"
reset; mk new 'sleep 3'; mk good 'sleep 3'; st new; touch $A/trial
for i in 1 2 3 4 5 6; do BID=boot$i launch; done
[ "$(grep -c 'demarrage de new' $T/log)" = 6 ] && ok "6 lancements de new" || ko "nombre de lancements de new"
BID=boot7 launch
tail -1 $T/log | grep -q "demarrage de good" && [ -e $S/new/BAD ] && ok "7e demarrage : new ecarte, good lance" || ko "boucle non rompue"

echo "L10 : un seul lanceur (et une seule application) a la fois"
reset; mk good 'sleep 5'; st good
( launch ) & sleep 2
launch
[ "$(grep -c 'demarrage de good' $T/log)" = 1 ] && ok "second lanceur refuse tant que l'application tourne" || ko "deux instances"
wait

echo "L11 : verrou perime (processus mort) repris"
reset; mk good 'sleep 3'; st good; mkdir -p $T/run/launch.lock; echo 999999 > $T/run/launch.lock/pid
launch
grep -q "demarrage de good" $T/log && ok "verrou perime repris" || ko "verrou perime bloque"

echo "L12 : signal TERM recu directement par l'application"
reset; mk good 'trap "echo got-term >> /tmp/qptest/sig; exit 0" TERM; while :; do sleep 1; done'; st good
( launch ) & sleep 2
run "kill \$(cat /tmp/qptest/run/launch.lock/pid)"; sleep 2
grep -q got-term $T/sig 2>/dev/null && ok "TERM recu par l'application" || ko "TERM non recu"
wait

echo "L13 : arret volontaire (expected_stop) non compte comme plantage"
reset; mk new 'exit 0'; mk good 'sleep 3'; st new
for i in 1 2 3 4 5; do launch; : > $A/expected_stop; done
[ ! -e $S/new/BAD ] && ok "arrets volontaires non comptes" || ko "arret volontaire compte"

echo "L14 : reglages Go transmis (liste blanche)"
reset; mk good 'echo "GOGC=$GOGC GOMEMLIMIT=$GOMEMLIMIT EVIL=$EVIL" > /tmp/qptest/env'; st good
printf 'GOGC=50\nGOMEMLIMIT=24MiB\nEVIL=1\nLD_PRELOAD=/x.so\n' > $T/qp/app.env
launch
grep -q "GOGC=50 GOMEMLIMIT=24MiB EVIL=$" $T/env && ok "GOGC/GOMEMLIMIT transmis, autres variables ignorees" || ko "reglages Go ($(cat $T/env))"

echo "L15 : plantage puis redemarrage de la camera -> non compte"
reset; mk new 'exit 1'; mk good 'sleep 3'; st new
for i in 1 2 3 4; do BID=b$i launch; done
[ ! -e $S/new/BAD ] && ok "arrets separes par des redemarrages non comptes comme rapides" || ko "comptes a tort"
echo "L16 : surveillance mutuelle : surveillant absent -> relance par le lanceur"
reset; mk good 'sleep 3'; st good; printf '#!/bin/sh\necho guard-lance >> /tmp/qptest/guard-started\n' > $T/qp/qp-guard
launch; sleep 1
[ -s $T/guard-started ] && grep -q "surveillant absent : relance" $T/log && ok "surveillant relance par le lanceur" || ko "surveillant non relance"
reset; mk good 'sleep 3'; st good; printf '#!/bin/sh\necho guard-lance >> /tmp/qptest/guard-started\n' > $T/qp/qp-guard
mkdir -p $T/run/guard.lock; chroot $ROOT /bin/sleep 20 & GP=$!; sleep 0.5; echo $GP > $T/run/guard.lock/pid
launch; sleep 1
[ ! -s $T/guard-started ] && ok "surveillant vivant : pas de second" || ko "second surveillant lance"
kill $GP 2>/dev/null; wait $GP 2>/dev/null
echo "L17 : (v4.1) essai dont le marqueur a disparu (ecriture perdue) -> marqueur recree, essai poursuivi"
reset; mk new 'sleep 3'; mk good 'sleep 3'; mk factory 'sleep 3'; st new; rm -f $A/trial
launch
grep -q "demarrage de new" $T/log && [ -e $A/trial ] && grep -q "marqueur d'essai absent" $T/log && ok "marqueur recree, new lance en essai" || ko "marqueur non recree"
grep -q "marqueur recree" $A/last_update_result && ok "resultat consigne sur la carte" || ko "resultat absent"
reset; mk good 'sleep 3'; mk factory 'sleep 3'; st good
launch
[ ! -e $A/trial ] && ok "aucun marqueur cree hors essai (good)" || ko "marqueur cree a tort"
reset; mk new 'sleep 3'; mk good 'sleep 3'; mk factory 'sleep 3'; st new; touch $A/trial; echo 6 > $A/new_starts
launch
grep -q "demarrage de good" $T/log && [ ! -e $A/trial ] && ok "new ecarte apres 6 lancements : pas de marqueur recree" || ko "marqueur recree pour un new ecarte"
summary
