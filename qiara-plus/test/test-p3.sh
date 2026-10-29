#!/bin/bash
# Essai a blanc du script detache de la phase P3 (tel que PowerShell l'envoie), dans une camera simulee.
. "$(dirname "$0")/lib.sh"
eval "$(sed -n '/^FA=/,/^restart_app/p' $(dirname "$0")/test-setup.sh)"
setup_dirs $FA/fakeapp $FA/fakeapp-v0
bootloop; sleep 2
setup install --yes > $T/out 2>&1 || { ko "installation prealable"; tail $T/out; }
cp $FA/fakeapp-v2 $T/v2.bin; mkdir -p $M/qp/incoming; cp $T/v2.bin $M/qp/incoming/openqiarad
W=$(sha256sum $T/v2.bin | cut -d' ' -f1)
# corps du script de P3 apres expansion PowerShell ($want remplace, `$ -> $), chemins de la camera -> camera simulee
sed -n '/^\$scr = @"/,/^"@/p' /mnt/user-data/outputs/phases6/P3-passage-claude6.ps1 | tr -d '\r' | sed '1d;$d' \
 | sed "s/\$want/$W/; s/\`\\\$/\$/g; s#/data/qp/qp-update#/tmp/qptest/data/qp/qp-update#; s#/data/qp/state#/tmp/qptest/data/qp/state#g; s#/media/qp/incoming#/tmp/qptest/media/qp/incoming#g; s#/tmp/qp-p3.lock#/tmp/qptest/qp-p3.lock#g" > $T/p3.sh
cat $T/p3.sh | sed 's/^/      | /'
chroot $ROOT /bin/sh -c "export $ENVS; setsid nohup sh /tmp/qptest/p3.sh > /tmp/qptest/p3.log 2>&1 < /dev/null &"; sleep 3
grep -q RELANCE $T/p3.log && ok "stage puis relance faits par le script detache" || { ko "script P3"; cat $T/p3.log; }
[ ! -e $M/qp/incoming/openqiarad ] && ok "depot retire apres le stage" || ko "depot reste"
waitfor 20 '[ "$(slotrun)" = new ]' && ok "essai lance (new)" || ko "new non lance"
waitfor 40 '[ ! -e $Q/state/trial ] && [ "$(shaof $B/slots/good/openqiarad)" = "$(shaof $FA/fakeapp-v2)" ]' && ok "essai valide automatiquement" || { ko "pas de validation"; tail -6 $D/openqiarad.log; }
[ ! -d $T/qp-p3.lock ] && ok "verrou libere" || ko "verrou reste"
chroot $ROOT /bin/sh -c "export $ENVS; sh /tmp/qptest/p3.sh" > $T/p3b.log 2>&1; grep -q "ECHEC stage" $T/p3b.log && ok "relance du script sans depot : echec propre, rien d'autre" || { ko "second passage"; cat $T/p3b.log; }
cleanup
summary
