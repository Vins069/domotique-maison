#!/bin/bash
. "$(dirname "$0")/lib.sh"
S=$T/bulk/slots; A=$T/qp/state

echo "U1 : amorcage (seed) d'origine et de reference"
reset; fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000
upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null
[ "$(sha256sum $T/orig.bin | cut -d' ' -f1)" = "$(sha256sum $T/qp/slots/factory/openqiarad | cut -d' ' -f1)" ] && ok "factory identique a l'original" || ko "factory different"
[ "$(sha256sum $T/cur.bin | cut -d' ' -f1)" = "$(sha256sum $S/good/openqiarad | cut -d' ' -f1)" ] && ok "good identique" || ko "good different"
[ "$(cat $A/active)" = good ] && ok "actif = good" || ko "actif incorrect"

echo "U2 : pre-controles de stage"
fake_elf $T/new.bin 1600000
printf '#!/bin/sh\necho x\n' > $T/script.bin
head -c 500000 /dev/urandom > $T/petit.bin
fake_elf $T/x86.bin 1500000; printf '\x03\x00' | dd of=$T/x86.bin bs=1 seek=18 conv=notrunc 2>/dev/null
upd stage /tmp/qptest/script.bin >/dev/null 2>&1; [ $? != 0 ] && ok "script refuse (pas ELF)" || ko "script accepte"
upd stage /tmp/qptest/petit.bin >/dev/null 2>&1; [ $? != 0 ] && ok "fichier trop petit refuse" || ko "petit accepte"
upd stage /tmp/qptest/x86.bin >/dev/null 2>&1; [ $? != 0 ] && ok "ELF non ARM refuse" || ko "x86 accepte"
upd stage /tmp/qptest/new.bin 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1; [ $? != 0 ] && ok "mauvaise empreinte attendue refusee" || ko "empreinte non verifiee"
[ ! -e $S/new/openqiarad ] && ok "rien depose apres refus" || ko "depot malgre refus"
[ "$(cat $A/active)" = good ] && ok "actif inchange apres refus" || ko "actif modifie"

echo "U3 : stage correct puis promote"
want=$(sha256sum $T/new.bin | cut -d' ' -f1)
upd stage /tmp/qptest/new.bin $want >/dev/null; [ $? = 0 ] && ok "stage accepte" || ko "stage refuse"
[ "$(cat $A/active)" = new ] && [ -e $A/trial ] && ok "actif = new, essai ouvert" || ko "etat apres stage"
[ "$(sha256sum $S/new/openqiarad | cut -d' ' -f1)" = "$want" ] && ok "empreinte de new exacte" || ko "new different"
[ ! -e $S/new/openqiarad.part ] && ok "pas de fichier .part" || ko ".part reste"
upd promote >/dev/null 2>&1; [ $? != 0 ] && ok "promote refuse si new ne tourne pas" || ko "promote sans execution"
echo new > $A/running_slot
upd promote >/dev/null 2>&1; [ $? != 0 ] && ok "promote refuse sans numero de processus enregistre (kill -0 0 visait tout le groupe)" || ko "promote accepte sans processus"
sleep 300 & UC=$!; sleep 0.3; echo $UC > $A/child
upd promote >/dev/null; [ $? = 0 ] && ok "promote accepte" || ko "promote refuse"
kill $UC 2>/dev/null; wait $UC 2>/dev/null
[ "$(sha256sum $S/good/openqiarad | cut -d' ' -f1)" = "$want" ] && ok "good = nouveau binaire" || ko "good non mis a jour"
[ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "actif = good, essai ferme" || ko "etat apres promote"
[ "$(sha256sum $T/qp/slots/factory/openqiarad | cut -d' ' -f1)" = "$(sha256sum $T/orig.bin | cut -d' ' -f1)" ] && ok "factory intact" || ko "factory touche"
[ "$(sha256sum $S/prev/openqiarad | cut -d' ' -f1)" = "$(sha256sum $T/cur.bin | cut -d' ' -f1)" ] && ok "ancienne version validee gardee en prev" || ko "prev absent"

echo "U4 : rollback"
fake_elf $T/new2.bin 1650000
upd stage /tmp/qptest/new2.bin >/dev/null
upd rollback "essai" >/dev/null
[ -e $S/new/BAD ] && [ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "new BAD, retour a good" || ko "rollback incomplet"
[ "$(sha256sum $S/good/openqiarad | cut -d' ' -f1)" = "$want" ] && ok "good intact" || ko "good modifie par rollback"

echo "U5 : restage apres rollback : le marquage BAD est efface"
upd stage /tmp/qptest/new2.bin >/dev/null
[ ! -e $S/new/BAD ] && ok "BAD efface par le nouveau depot" || ko "BAD persiste"

echo "U6 : disque plein -> refus propre, rien de casse"
reset; fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null
fake_elf $T/new.bin 1600000
run "$ENVV QP_FAKE_FREE=1000 QP_MIN_SIZE=1000000 /tmp/qptest/qp/qp-update stage /tmp/qptest/new.bin" >/dev/null 2>&1; [ $? != 0 ] && ok "refus faute de place" || ko "depot malgre manque de place"
[ "$(cat $A/active)" = good ] && ok "actif inchange" || ko "actif modifie"
slot_ok=$(run "$ENVV /tmp/qptest/qp/qp-update status" | grep -c 'slot_good=.*valid=1'); [ "$slot_ok" = 1 ] && ok "good toujours valide" || ko "good invalide"

echo "U7 : coupure pendant la copie (fichier .part laisse) -> jamais utilise"
reset; fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null
mkdir -p $S/new; head -c 700000 $T/orig.bin > $S/new/openqiarad.part
echo new > $A/active
launch >/dev/null 2>&1
! grep -q "demarrage de new" $T/log && grep -q "demarrage de good" $T/log && ok "new sans binaire complet : ignore, good lance (fichier partiel jamais utilise)" || ko "fichier partiel utilise"
run "$ENVV /tmp/qptest/qp/qp-update status" > /dev/null

echo "U8 : statut lisible"
reset; fake_elf $T/orig.bin 1500000; upd seed-factory /tmp/qptest/orig.bin >/dev/null
run "$ENVV /tmp/qptest/qp/qp-update status" | grep -q '^slot_factory=' && ok "status liste factory" || ko "status incomplet"
echo "U9 : retour a la version precedente apres validation (use-prev)"
reset; fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null; upd stage /tmp/qptest/new.bin >/dev/null; upd promote --force >/dev/null
upd use-prev >/dev/null; [ "$(cat $A/active)" = prev ] && ok "actif = prev" || ko "use-prev"
mk prev 'sleep 3'; launch >/dev/null 2>&1
grep -q "demarrage de prev" $T/log && ok "le lanceur demarre prev" || ko "prev non lance"
echo "U10 : good ecarte -> repli sur prev avant factory"
reset; mk good 'sleep 3'; mk prev 'sleep 3'; mk factory 'sleep 3'; mkdir -p $A; echo good > $A/active
read -r U _ < /proc/uptime; echo "$(cat /proc/sys/kernel/random/boot_id) ${U%%.*} $(date +%s)" > $S/good/BAD
launch >/dev/null 2>&1
grep -q "demarrage de prev" $T/log && ok "repli sur prev" || ko "pas de repli sur prev"
summary
