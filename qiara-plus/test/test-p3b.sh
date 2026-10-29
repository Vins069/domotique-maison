#!/bin/bash
# Essai a blanc de P3b : script detache ENVOYE par la commande exacte du .ps1 (cat sur l'entree standard, puis lancement).
. "$(dirname "$0")/lib.sh"
eval "$(sed -n '/^FA=/,/^restart_app/p' $(dirname "$0")/test-setup.sh)"
setup_dirs $FA/fakeapp $FA/fakeapp-v0
bootloop; sleep 2
setup install --yes > $T/out 2>&1 || { ko "installation prealable"; tail $T/out; }
cp $FA/fakeapp-v2 $T/v2.bin; mkdir -p $M/qp/incoming; cp $T/v2.bin $M/qp/incoming/openqiarad
W=$(sha256sum $T/v2.bin | cut -d' ' -f1)
PS=/mnt/user-data/outputs/phases6/P3b-passage-claude6.ps1
sub() { sed "s#/data/qp/qp-update#/tmp/qptest/data/qp/qp-update#; s#/data/qp/state#/tmp/qptest/data/qp/state#g; s#/media/qp/incoming#/tmp/qptest/media/qp/incoming#g; s#/tmp/qp-p3#/tmp/qptest/qp-p3#g"; }
sed -n '/^\$scr = @"/,/^"@/p' $PS | tr -d '\r' | sed '1d;$d' | sed "s/\$want/$W/; s/\`\\\$/\$/g" | sub > $T/p3-contenu.sh
# commande distante exacte (entre les apostrophes de Envoi), chemins adaptes au banc
CMD=$(grep -o "Envoi \$b '.*'" $PS | tr -d '\r' | sed "s/^Envoi \$b '//; s/'\$//" | sub)
echo "      commande : $CMD"
OUT=$(chroot $ROOT /bin/sh -c "export $ENVS; $CMD" < $T/p3-contenu.sh 2>&1)
echo "      sortie : $OUT"
echo "$OUT" | grep -q "script : [1-9][0-9]* octets" && ok "le script detache n'est pas vide" || ko "script vide"
waitfor 10 'grep -q RELANCE $T/qp-p3.log' && ok "stage puis relance faits" || { ko "pas de relance"; cat $T/qp-p3.log; }
waitfor 20 '[ "$(slotrun)" = new ]' && ok "essai lance (new)" || ko "new non lance"
waitfor 40 '[ ! -e $Q/state/trial ] && [ "$(shaof $B/slots/good/openqiarad)" = "$(shaof $FA/fakeapp-v2)" ]' && ok "essai valide automatiquement" || { ko "pas de validation"; tail -6 $D/openqiarad.log; }
[ "$(shaof $B/slots/prev/openqiarad)" = "$(shaof $FA/fakeapp)" ] && ok "ancienne version gardee en prev" || ko "prev absent"
[ ! -d $T/qp-p3.lock ] && ok "verrou libere" || ko "verrou reste"
cleanup
summary
