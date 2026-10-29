#!/bin/bash
# Essais a blanc des durcissements v6 de Qiara Plus (27/10/2026) et plan d'injection de pannes rejouable hors ligne :
# horloge murale qui saute (1970 -> 2026), redemarrages simules (numero de demarrage et uptime), fichiers d'etat tronques ou
# abimes, numeros de processus perimes, ecriture impossible (disque plein simule), configuration abimee, mise a jour sous
# l'application. Banc : voir lib.sh (dash, QP_BENCH_ROOT). Rien n'est ecrit sur la camera.
. "$(dirname "$0")/lib.sh"
A=$T/qp/state; R=$T/run; S=$T/bulk/slots
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "$@" > $T/qp/guard.conf; }
# horloge murale simulee : le bouchon « date » repond a +%s avec /tmp/qptest/fake_now (s'il existe), sinon la vraie date
clock() { echo "$1" > $T/fake_now; }
fake_clock() { printf '#!/bin/sh\nif [ -s /tmp/qptest/fake_now ]; then read -r n < /tmp/qptest/fake_now; case "$*" in *%%s*) echo "$n"; exit 0;; esac; fi\nexec /bin/date "$@"\n' > $T/stubs/date; chmod +x $T/stubs/date; }
# uptime simule (QP_UPTIME) et numero de demarrage simule (QP_BOOT_ID) : un « redemarrage » = nouveau BID, uptime remis bas, /tmp vide
upfile() { echo "$1.00 0.00" > $T/uptime; }
UPENV="QP_UPTIME=/tmp/qptest/uptime"
guardu() { run "$ENVV $UPENV QP_BOOT_ID=${BID:-b1} QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=${APPCOMM:-sleep} QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
launchu() { run "$ENVV $UPENV QP_BOOT_ID=${BID:-b1} QP_STABLE_SEC=${STABLE:-2} QP_GAP_SEC=0 QP_MAXFAIL=3 QP_NOBIN_SLEEP=1 QP_NO_GUARD=1 /tmp/qptest/qp-launch -web :80 -log /x" ; }
reboot_sim() { BID=$1; upfile "${2:-30}"; rm -rf $R; mkdir -p $R; }
upt() { read -r u _ < /proc/uptime; echo ${u%%.*}; }
bid() { cat /proc/sys/kernel/random/boot_id; }
fakechild() { mkdir -p $A $R; chroot $ROOT /bin/sleep 300 & CH=$!; sleep 0.5
  echo $CH > $A/child; echo ${2:-good} > $A/running_slot; echo $(( $(upt) - ${1:-400} )) > $A/run_up; bid > $A/run_boot; }
killchild() { kill $CH 2>/dev/null; wait $CH 2>/dev/null; }
alive() { kill -0 ${1:-$CH} 2>/dev/null; }
proc_named() { cp "$(command -v sleep)" "$T/$1"; "$T/$1" 300 & PN=$!; sleep 0.4; }
seed3() { fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
  upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null; upd stage /tmp/qptest/new.bin >/dev/null; }
reboots() { grep -c reboot $T/calls 2>/dev/null; }

echo "X1 : rate_ok sur l'uptime : 3 redemarrages a l'horloge de 1970, puis saut en 2026 -> le 4e reste refuse (meme demarrage)"
reset; conf ORDER_REBOOT_MAX=3 REBOOT_WINDOW=21600; fake_clock; upfile 1000; mkdir -p $R/cmd      # les ordres HA ont leur budget (X19) : 3 ici pour l'essai
for i in 1 2 3; do clock $((1000 + i * 10)); upfile $((1000 + i * 10)); : > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2; done
[ "$(reboots)" = 3 ] && ok "3 redemarrages acceptes a l'horloge de 1970" || ko "$(reboots) redemarrages"
clock 1761500000; upfile 1040; : > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 3 ] && grep -q "redemarrage refuse" $T/log && ok "saut de l'horloge vers 2026 : 4e redemarrage refuse (v5 l'aurait accepte)" || ko "4e redemarrage accepte apres le saut d'horloge ($(reboots))"
grep -q ':b1' $A/rate_order_reboot && ok "evenements notes avec uptime et numero de demarrage" || ko "format : $(cat $A/rate_order_reboot)"
echo "X2 : rate_ok apres un redemarrage sans heure fiable : compte tant que la camera n'a pas tourne toute la fenetre"
reboot_sim b2 50; clock 60; mkdir -p $R/cmd; : > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 3 ] && ok "autre demarrage, horloge de 1970 : les 3 evenements restent comptes (age = uptime courant)" || ko "oublies au redemarrage ($(reboots))"
upfile 21700; clock 21710; : > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 4 ] && ok "apres une fenetre entiere d'uptime : de nouveau autorise" || ko "toujours refuse apres la fenetre ($(reboots))"
echo "X3 : rate_ok apres un redemarrage avec heure fiable des deux cotes : age reel (horloge)"
reset; conf ORDER_REBOOT_MAX=3 REBOOT_WINDOW=21600; fake_clock; mkdir -p $A $R/cmd
echo "100:1761400000:b0 110:1761400010:b0 120:1761400020:b0" > $A/rate_order_reboot      # 3 redemarrages il y a ~28 h
upfile 100; clock 1761500000; : > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 1 ] && ok "evenements vieux de 28 h (horloge plausible) expires : autorise" || ko "refuse a tort ($(reboots))"
echo "X4 : ancien fichier rate_* de la v5 (horloge seule) lu sans erreur"
reset; conf ORDER_REBOOT_MAX=3; fake_clock; mkdir -p $A $R/cmd; echo "1761400000 1761400010 12x 08" > $A/rate_order_reboot
upfile 500; clock 1761400100; : > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 1 ] && ok "2 evenements recents (ancien format) + 1 nouveau : accepte" || ko "ancien format ($(reboots))"
: > $R/cmd/reboot; ONCE=1 guardu >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 1 ] && ok "4e refuse : les anciens evenements comptent" || ko "anciens evenements ignores ($(reboots))"

echo "X5 : boucle de redemarrages par passerelle muette, sans heure : au plus REBOOT_MAX par fenetre sur plusieurs demarrages"
reset; conf NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=3 REBOOT_MAX=2 REBOOT_WINDOW=21600; fake_clock; touch $T/net_down
for b in 1 2 3 4 5; do reboot_sim b$b 20; clock 25; ( for i in 1 2 3 4 5 6 7 8; do sleep 1; echo "$((20 + i * 2)).00 0.00" > $T/uptime; done ) & ONCE=6 guardu >/dev/null 2>&1; wait; done
[ "$(reboots)" = 2 ] && ok "5 demarrages consecutifs sans passerelle : 2 redemarrages seulement" || ko "$(reboots) redemarrages en 5 demarrages"
[ "$(grep -c 'redemarrage refuse' $T/log)" -le 12 ] && ok "refus journalise au plus une fois par NET_L3_SEC (et non a chaque tour) ($(grep -c 'redemarrage refuse' $T/log))" || ko "journal inonde : $(grep -c 'redemarrage refuse' $T/log) refus"

echo "X6 : marquage BAD pose a l'horloge de 1970 -> expire apres QP_BAD_BOOTS demarrages (v5 : jamais)"
reset; mk good 'sleep 1'; mk prev 'sleep 1'; mkdir -p $A; echo good > $A/active; fake_clock; clock 900; upfile 800
echo "b1 700 900 1" > $S/good/BAD; echo "b1 1" > $A/boot_seq
BID=b2 launchu >/dev/null 2>&1; grep -q "demarrage de prev" $T/log && [ -e $S/good/BAD ] && ok "1er demarrage suivant : BAD conserve (prev lance)" || ko "BAD perdu trop tot"
[ "$(cat $A/boot_seq)" = "b2 2" ] && ok "numero de demarrage incremente par le lanceur" || ko "boot_seq : $(cat $A/boot_seq)"
: > $T/log; BID=b3 launchu >/dev/null 2>&1; grep -q "demarrage de good" $T/log && [ ! -e $S/good/BAD ] && ok "2e demarrage suivant : BAD expire, good retente" || ko "BAD permanent"
: > $T/log; echo "autre 10 5" > $S/good/BAD; BID=b4 launchu >/dev/null 2>&1; grep -q "demarrage de prev" $T/log && ok "ancien format sans numero : conserve par prudence (comportement v5)" || ko "ancien format expire"
echo "X7 : fichiers d'etat tronques ou abimes -> le lanceur lance quand meme la bonne version"
reset; mk good 'sleep 1'; mk prev 'sleep 1'; mk factory 'sleep 1'; mkdir -p $A
: > $A/active; printf 'xx\n' > $A/fails; printf '\n' > $A/new_starts; printf 'abc\n' > $A/child; printf 'zz' > $A/run_up; : > $A/boot_seq; : > $S/good/BAD; printf 'garbage' > $S/prev/BAD
launchu >/dev/null 2>&1; rc=$?
grep -q "demarrage de good" $T/log && ok "active vide, compteurs abimes, BAD vide : good lance (BAD vide = expire)" || { ko "lancement rate (rc=$rc)"; tail -3 $T/log; }
: > $A/active; echo "0000" > $S/good/openqiarad.sha256; : > $S/prev/openqiarad.sha256
launchu >/dev/null 2>&1
grep -q "demarrage de factory" $T/log && ok "empreintes abimees (fausse, vide) : repli sur factory" || ko "empreinte abimee acceptee"
echo "X8 : ecriture impossible dans l'etat (disque plein simule : dossiers a la place des fichiers) -> l'application est lancee"
reset; mk good 'echo lance >> /tmp/qptest/args; sleep 1'; mkdir -p $A; echo good > $A/active
for f in fails running_slot run_boot run_up child boot_seq; do mkdir -p $A/$f; done
launchu >/dev/null 2>&1
[ -s $T/args ] && ok "application lancee malgre l'etat non inscriptible" || ko "lanceur bloque par l'etat non inscriptible"
echo "X9 : guard.conf : valeur numerique abimee -> defaut conserve (v5 : valait 1) ; GATEWAY fausse ignoree"
reset; conf "REBOOT_WINDOW=216x0" "HEALTH_STALE=" "REBOOT_MAX=3" "GATEWAY=192.0.2.x"; ONCE=1 guard >/dev/null 2>&1
grep -q "REBOOT_WINDOW=216x0 invalide, defaut 21600" $T/log && ok "REBOOT_WINDOW invalide : defaut 21600 conserve et journalise" || ko "$(grep REBOOT_WINDOW $T/log)"
grep -q "HEALTH_STALE= invalide, defaut 180" $T/log && ok "valeur vide : defaut conserve" || ko "$(grep HEALTH_STALE $T/log)"
grep -q "GATEWAY=192.0.2.x invalide" $T/log && ok "GATEWAY non numerique ignoree (table de routage)" || ko "GATEWAY acceptee"
reset; conf "GATEWAY=192.0.2.300"; ONCE=1 guard >/dev/null 2>&1; grep -q "GATEWAY=192.0.2.300 invalide" $T/log && ok "octet > 255 refuse" || ko "octet > 255 accepte"
reset; conf "GATEWAY=192.0.2.254" "TICK=0" HEALTH_GRACE=1 HEALTH_STALE=5; fakechild 400; printf 'ts=5\nup=%s\nmqtt=1\napp_ok=1\n' "$(upt)" > $R/health
ONCE=2 guard >/dev/null 2>&1; ! grep -q "GATEWAY=192.0.2.254 invalide" $T/log && alive && ok "adresse correcte acceptee, TICK=0 ramene a 1, application saine intacte" || ko "adresse correcte refusee ou arret"
killchild
echo "X10 : app.env abime -> ligne refusee, les bonnes gardees ; factory en boucle d'arrets rapides -> lance sans app.env"
reset; mk good 'echo "GOGC=$GOGC GOMEMLIMIT=$GOMEMLIMIT GODEBUG=$GODEBUG" > /tmp/qptest/env; sleep 1'; mkdir -p $A; echo good > $A/active
printf 'GOGC=75\nGOMEMLIMIT=32MiX\nGODEBUG=madvdontneed=1\nGOMAXPROCS=abc\n' > $T/qp/app.env
launchu >/dev/null 2>&1
grep -q "GOGC=75 GOMEMLIMIT= GODEBUG=madvdontneed=1" $T/env && ok "GOMEMLIMIT=32MiX refuse, GOGC et GODEBUG transmis" || ko "env : $(cat $T/env)"
grep -q "app.env : ligne refusee (GOMEMLIMIT=32MiX)" $T/log && grep -q "ligne refusee (GOMAXPROCS=abc)" $T/log && ok "refus journalises" || ko "refus non journalises"
printf 'GOMEMLIMIT=32MiB\nGOGC=off\n' > $T/qp/app.env; launchu >/dev/null 2>&1
grep -q "GOGC=off GOMEMLIMIT=32MiB" $T/env && ok "formes valides (32MiB, off) acceptees" || ko "env : $(cat $T/env)"
reset; mk factory 'echo "L=$GOMEMLIMIT" >> /tmp/qptest/env; exit 1'; mkdir -p $A; echo factory > $A/active; printf 'GOMEMLIMIT=32MiB\n' > $T/qp/app.env
for i in 1 2 3; do launchu >/dev/null 2>&1; done
[ "$(grep -c 'L=32MiB' $T/env)" = 3 ] && ok "3 premiers lancements de factory avec app.env" || ko "$(cat $T/env)"
launchu >/dev/null 2>&1; tail -1 $T/env | grep -q '^L=$' && grep -q "app.env ignore (factory arrete 3 fois" $T/log && ok "4e lancement : sans app.env, journalise" || ko "app.env toujours applique : $(tail -1 $T/env)"
[ ! -e $T/qp/slots/factory/BAD ] && ok "factory toujours pas marque BAD" || ko "factory BAD"
echo "X11 : instantanes dates de 1970 (horloge pas reglee) -> comptes et elagues comme les autres"
reset; conf NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=600; touch $T/net_down; mkdir -p $T/bulk/incidents
for i in 1 2 3 4 5 6 7; do mkdir -p $T/bulk/incidents/19700101-00000$i; done
run "$ENVV QP_BB_LOG=/tmp/qptest/bb.log QP_SAMPLES=/tmp/qptest/vision.samples QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=4 /tmp/qptest/qp-guard" >/dev/null 2>&1
nn=$(ls -d $T/bulk/incidents/[0-9]* | wc -l); [ "$nn" = 6 ] && [ ! -d $T/bulk/incidents/19700101-000001 ] && ok "6 gardes, les plus anciens de 1970 retires" || ko "$nn dossiers : $(ls $T/bulk/incidents | tr '\n' ' ')"
echo "X12 : ordres repetes : use-prev limite et idempotent ; ordre qui n'est pas un fichier ignore"
reset; seed3; upd promote --force >/dev/null 2>&1; conf; mkdir -p $R/cmd
for i in 1 2 3 4 5 6 7 8; do : > $R/cmd/use-prev; ONCE=1 guard >/dev/null 2>&1; done
[ "$(grep -c 'retour demande a la version precedente' $T/log)" = 6 ] && grep -q "ordre HA refuse (6 relances par heure au plus) : use-prev" $T/log && ok "use-prev : 6 executions sur 8, refus journalise" || ko "use-prev : $(grep -c 'retour demande a la version precedente' $T/log) executions"
reset; seed3; upd promote --force >/dev/null 2>&1; upd use-prev >/dev/null 2>&1; proc_named openqiarad; echo $PN > $A/child; echo prev > $A/running_slot
APPCOMM=openqiarad upd use-prev >/dev/null 2>&1; sleep 0.5
alive $PN && grep -q "deja en cours" $T/log && ok "use-prev repete alors que prev tourne : application non relancee" || ko "application relancee a tort"
kill $PN 2>/dev/null; wait $PN 2>/dev/null
reset; conf; mkdir -p $R/cmd/reboot; ONCE=1 guard >/dev/null 2>&1
! grep -q reboot $T/calls && grep -q "ordre ignore (pas un fichier) : reboot" $T/log && [ ! -e $R/cmd/reboot ] && ok "dossier nomme reboot : ignore, retire, pas de redemarrage" || ko "dossier traite comme un ordre"
echo "X13 : depot (stage) pendant un essai en cours -> refuse ; validation d'un binaire remplace -> refusee"
reset; seed3; proc_named openqiarad; echo $PN > $A/child; echo new > $A/running_slot; fake_elf $T/new2.bin 1650000
APPCOMM=openqiarad upd stage /tmp/qptest/new2.bin >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && [ "$(sha256sum $S/new/openqiarad | cut -d' ' -f1)" = "$(sha256sum $T/new.bin | cut -d' ' -f1)" ] && ok "stage refuse, new intact" || ko "stage accepte pendant l'essai (rc=$rc)"
APPCOMM=openqiarad upd promote >/dev/null 2>&1 && ok "promote accepte quand new est bien le binaire depose (controle positif)" || ko "promote refuse a tort"
kill $PN 2>/dev/null; wait $PN 2>/dev/null
reset; seed3; proc_named openqiarad; echo $PN > $A/child; echo new > $A/running_slot; fake_elf $T/new2.bin 1650000
cp $T/new2.bin $S/new/openqiarad; sha256sum $S/new/openqiarad | cut -d' ' -f1 > $S/new/openqiarad.sha256      # remplace sous l'application, empreinte « coherente »
APPCOMM=openqiarad upd promote >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && [ "$(sha256sum $S/good/openqiarad | cut -d' ' -f1)" = "$(sha256sum $T/cur.bin | cut -d' ' -f1)" ] && ok "promote refuse (empreinte differente de celle de l'essai), good intact" || ko "binaire jamais essaye promu (rc=$rc)"
kill $PN 2>/dev/null; wait $PN 2>/dev/null
reset; seed3; cp "$(command -v sleep)" $T/openqiarad; $T/openqiarad 300 & PN=$!; sleep 0.4; rm -f $T/openqiarad     # executable supprime sous le processus
echo $PN > $A/child; echo new > $A/running_slot; echo "$(date +%s)" > $A/trial                          # marqueur sans empreinte (ancien format)
APPCOMM=openqiarad upd promote >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && grep -q "remplace sous l'application" $T/log && ok "executable (deleted) : validation refusee" || ko "validation d'un executable supprime (rc=$rc)"
kill $PN 2>/dev/null; wait $PN 2>/dev/null
echo "X14 : marqueur d'essai recree par le lanceur avec l'empreinte"
reset; mk new 'sleep 1'; mk good 'sleep 1'; mkdir -p $A; echo new > $A/active; launchu >/dev/null 2>&1
read -r tw ts < $A/trial; [ "$ts" = "$(sha256sum $S/new/openqiarad | cut -d' ' -f1)" ] && ok "marqueur « date empreinte »" || ko "marqueur : $(cat $A/trial)"
echo "X15 : horloge de l'application en 1970 puis 2026 pendant l'essai -> validation sur l'uptime, pas sur l'horloge"
reset; seed3; conf PROMOTE_AFTER=1; fakechild 400 new; fake_clock; clock 1000
printf 'ts=1000\nup=%s\nmqtt=1\napp_ok=1\n' "$(upt)" > $R/health; ONCE=1 guard >/dev/null 2>&1
[ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "essai sain valide a l'horloge de 1970" || ko "validation bloquee par l'horloge"
killchild
echo "X16 : place libre sur /media publiee dans guard-status"
reset; conf; run "$ENVV QP_MEDIA_DF=/tmp QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=1 /tmp/qptest/qp-guard" >/dev/null 2>&1
grep -q '^media_free_kb=[0-9]' $R/guard-status && ok "media_free_kb numerique" || ko "$(grep media_free $R/guard-status)"
echo "X17 : copie de secours (openqiarad.old) : acceptee sans empreinte ou avec la bonne, refusee avec une mauvaise"
OLDENV="QP_OLD=/tmp/qptest/old/openqiarad.old"
launcho() { run "$ENVV $OLDENV QP_STABLE_SEC=2 QP_GAP_SEC=0 QP_MAXFAIL=3 QP_NOBIN_SLEEP=1 QP_NO_GUARD=1 /tmp/qptest/qp-launch -web :80" ; }
reset; mkdir -p $T/old; printf '#!/bin/sh\necho old >> /tmp/qptest/args; sleep 1\n' > $T/old/openqiarad.old; chmod +x $T/old/openqiarad.old
launcho >/dev/null 2>&1; grep -q "^old" $T/args && grep -q "repli sur /tmp/qptest/old/openqiarad.old" $T/log && ok "sans empreinte : acceptee (comportement v5)" || ko "copie sans empreinte refusee"
sha256sum $T/old/openqiarad.old | cut -d' ' -f1 > $T/old/openqiarad.old.sha256; : > $T/args; launcho >/dev/null 2>&1
grep -q "^old" $T/args && ok "empreinte conforme : acceptee" || ko "empreinte conforme refusee"
echo 0000 > $T/old/openqiarad.old.sha256; : > $T/args; : > $T/log; launcho >/dev/null 2>&1; rc=$?
[ ! -s $T/args ] && [ $rc = 1 ] && grep -q "empreinte differente" $T/log && grep -q "AUCUN binaire" $T/log && ok "empreinte fausse : refusee, sortie 1" || ko "copie abimee executee (rc=$rc)"
echo "X18 : seed-good et promote rafraichissent la copie de secours, avec empreinte ; echec de copie non bloquant"
updo() { run "$ENVV QP_NO_OLD= $OLDENV QP_APP_COMM=sleep QP_MIN_SIZE=1000000 /tmp/qptest/qp/qp-update $*" ; }
reset; mkdir -p $T/old; fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
updo seed-factory /tmp/qptest/orig.bin >/dev/null; [ ! -e $T/old/openqiarad.old ] && ok "seed-factory ne touche pas la copie de secours" || ko "copie ecrite par seed-factory"
updo seed-good /tmp/qptest/cur.bin >/dev/null
[ "$(sha256sum $T/old/openqiarad.old | cut -d' ' -f1)" = "$(sha256sum $T/cur.bin | cut -d' ' -f1)" ] && read -r w _ < $T/old/openqiarad.old.sha256 && [ "$w" = "$(sha256sum $T/cur.bin | cut -d' ' -f1)" ] && ok "seed-good : copie = good, empreinte ecrite" || ko "copie non rafraichie par seed-good"
updo stage /tmp/qptest/new.bin >/dev/null; updo promote --force >/dev/null
[ "$(sha256sum $T/old/openqiarad.old | cut -d' ' -f1)" = "$(sha256sum $T/new.bin | cut -d' ' -f1)" ] && [ ! -e $T/old/openqiarad.old.part ] && ok "promote : copie = nouveau good, pas de .part" || ko "copie non rafraichie par promote"
grep -q "copie de secours .* mise a jour" $T/log && ok "journalise" || ko "non journalise"
rm -rf $T/old; : > $T/old                            # un fichier a la place du dossier : copie impossible
fake_elf $T/new2.bin 1650000; updo stage /tmp/qptest/new2.bin >/dev/null; updo promote --force >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(cat $A/active)" = good ] && grep -q "non mise a jour" $T/log && ok "copie impossible : promote reussit quand meme, echec journalise" || ko "promote bloque par la copie de secours (rc=$rc)"
rm -f $T/old
echo "X19 : budget de redemarrages separe : ordres HA (2 par 6 h quand ORDER_REBOOT_MAX=2) et automatismes (3 par 6 h)"
reset; conf NET_L1_SEC=1 NET_L2_SEC=2 NET_L3_SEC=3 ORDER_REBOOT_MAX=2; mkdir -p $R/cmd
for i in 1 2 3; do : > $R/cmd/reboot; ONCE=1 guard >/dev/null 2>&1; sleep 1.2; done
[ "$(reboots)" = 2 ] && grep -q "deja 2 sur ordre" $T/log && ok "3 ordres HA : 2 redemarrages, 3e refuse" || ko "$(reboots) redemarrages sur ordre"
[ ! -s $A/rate_reboot ] && [ -s $A/rate_order_reboot ] && ok "budget automatique intact" || ko "budgets confondus"
touch $T/net_down; ONCE=6 guard >/dev/null 2>&1; sleep 1.2      # sur le banc, le bouchon reboot ne redemarre rien : la boucle peut redemander apres NET_L3_SEC
[ "$(reboots)" -ge 3 ] && [ -s $A/rate_reboot ] && ok "redemarrage automatique (passerelle muette) toujours possible, compte dans son propre budget" || ko "automatique bloque par les ordres ($(reboots))"
# v10 : ORDER_REBOOT_MAX=0 (defaut) = ordres HA sans limite ; ENABLE_REBOOT=0 reste le moyen de tout interdire
reset; conf ORDER_REBOOT_MAX=0; mkdir -p $R/cmd
for i in 1 2 3 4 5; do : > $R/cmd/reboot; ONCE=1 guard >/dev/null 2>&1; sleep 1.2; done
[ "$(reboots)" = 5 ] && ! grep -q "sur ordre" $T/log && [ ! -s $A/rate_order_reboot ] && ok "ORDER_REBOOT_MAX=0 : 5 ordres HA, 5 redemarrages, aucun refus (v10)" || ko "ordres limites malgre 0 : $(reboots)"
reset; mkdir -p $R/cmd; for i in 1 2 3 4; do : > $R/cmd/reboot; ONCE=1 guard >/dev/null 2>&1; sleep 1.2; done
[ "$(reboots)" = 4 ] && ok "sans guard.conf : ordres HA sans limite par defaut (v10)" || ko "defaut limite : $(reboots)"
reset; conf ORDER_REBOOT_MAX=0 ENABLE_REBOOT=0; mkdir -p $R/cmd; : > $R/cmd/reboot; ONCE=1 guard >/dev/null 2>&1; sleep 1.2
[ "$(reboots)" = 0 ] && grep -q "desactive" $T/log && ok "ENABLE_REBOOT=0 interdit aussi les ordres HA" || ko "ordre execute malgre ENABLE_REBOOT=0"
summary
