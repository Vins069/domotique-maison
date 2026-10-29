#!/bin/bash
# Essai a blanc du script d'essai en memoire vive : boucle de boot.sh simulee, ancienne et nouvelle versions = fausses applications ARM.
. "$(dirname "$0")/lib.sh"
FA=/tmp/fakeapp
cleanup() { for p in /proc/[0-9]*; do [ "$(readlink $p/root 2>/dev/null)" = "$ROOT" ] && kill -9 ${p#/proc/} 2>/dev/null; done; sleep 1; }
cleanup; rm -rf $T $ROOT/tmp/qpt; mkdir -p $T/data $ROOT/tmp/qpt/qp
cp $FA/fakeapp $T/data/openqiarad; chmod 755 $T/data/openqiarad; echo '{"web":{}}' > $T/data/openqiara.json; : > $T/data/openqiarad.log
cp $FA/fakeapp-v2 $ROOT/tmp/qpt/oq5; chmod 755 $ROOT/tmp/qpt/oq5
cp $QP_DIST/qp-guard $ROOT/tmp/qpt/qp/qp-guard
cp "$(dirname "$0")/../trial/essai-memoire-vive.sh" $ROOT/tmp/qpt/essai.sh
chroot $ROOT /bin/sh -c "while :; do /tmp/qptest/data/openqiarad -web :18080 -log /x >/dev/null 2>&1; echo boucle-relance >> /tmp/qptest/loop.log; sleep 2; done" & sleep 3
old=$(grep -lx openqiarad /proc/[0-9]*/comm 2>/dev/null | head -1 | cut -d/ -f3)
echo "E1 : essai de 40 s"
chroot $ROOT /bin/sh -c "QPT_APP=/tmp/qptest/data/openqiarad QPT_CFG=/tmp/qptest/data/openqiara.json QPT_WEB=:18081 QPT_LEVEL=info sh /tmp/qpt/essai.sh 40" &
ES=$!; sleep 12
grep -lx oq5 /proc/[0-9]*/comm >/dev/null 2>&1 && ok "nouvelle version en marche" || ko "nouvelle version absente"
st=$(awk '/^State/{print $2}' /proc/$(awk '/^PPid/{print $2}' /proc/$old/status 2>/dev/null)/status 2>/dev/null)
[ ! -s $T/loop.log ] && ok "boucle de boot.sh suspendue (aucune relance de l'ancienne version)" || ko "la boucle a relance l'ancienne version"
grep -q "surveillant passif" $ROOT/tmp/qpt/essai.log && ok "surveillant passif lance" || ko "surveillant absent"
wait $ES
grep -q "retour : duree ecoulee" $ROOT/tmp/qpt/essai.log && ok "retour automatique en fin de duree" || ko "pas de retour"
grep -q "ancienne version revenue" $ROOT/tmp/qpt/essai.log && ok "ancienne version revenue" || ko "ancienne version non revenue"
grep -qE "t=3[0-9] s" $ROOT/tmp/qpt/essai.log && grep -q "RssAnon" $ROOT/tmp/qpt/essai.log && ok "mesures memoire relevees" || ko "pas de mesures"
! grep -lx oq5 /proc/[0-9]*/comm >/dev/null 2>&1 && ok "nouvelle version arretee" || ko "nouvelle version encore la"
grep -q "(passif, non fait)\|surveillant demarre" $ROOT/tmp/qpt/guard.log && ok "journal du surveillant passif present" || ko "journal du surveillant"
cat $ROOT/tmp/qpt/essai.log | sed 's/^/        /' | head -14
echo "E2 : la nouvelle version s'arrete d'elle-meme -> retour immediat"
cp $FA/fakeapp-crash $ROOT/tmp/qpt/oq5
chroot $ROOT /bin/sh -c "QPT_APP=/tmp/qptest/data/openqiarad QPT_CFG=/tmp/qptest/data/openqiara.json QPT_WEB=:18081 QPT_LEVEL=info sh /tmp/qpt/essai.sh 300" &
ES=$!; t0=$SECONDS; wait $ES; d=$((SECONDS - t0))
grep -q "retour : la nouvelle version s'est arretee" $ROOT/tmp/qpt/essai.log && [ $d -lt 120 ] && ok "retour en $d s" || ko "pas de retour rapide ($d s)"
grep -q "ancienne version revenue" $ROOT/tmp/qpt/essai.log && ok "ancienne version revenue" || ko "ancienne version non revenue"
echo "E3 : ordre d'arret (fichier STOP)"
cp $FA/fakeapp-v2 $ROOT/tmp/qpt/oq5
chroot $ROOT /bin/sh -c "QPT_APP=/tmp/qptest/data/openqiarad QPT_CFG=/tmp/qptest/data/openqiara.json QPT_WEB=:18081 QPT_LEVEL=info sh /tmp/qpt/essai.sh 300" &
ES=$!; sleep 8; touch $ROOT/tmp/qpt/STOP; t0=$SECONDS; wait $ES; d=$((SECONDS - t0)); rm -f $ROOT/tmp/qpt/STOP
grep -q "retour : ordre d'arret" $ROOT/tmp/qpt/essai.log && [ $d -lt 90 ] && ok "arret sur ordre en $d s" || ko "ordre d'arret ($d s)"
cleanup
summary
