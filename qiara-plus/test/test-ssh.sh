#!/bin/bash
# Essais a blanc des ajouts v8 de Qiara Plus (27/10/2026) : dropbear 2222 relance avec maintien de connexion, ordre
# ssh-restart de Home Assistant (liste fermee, 6 par heure, processus verifie par son nom), codec video demande a hlcamd.
# Banc : voir lib.sh (QP_BENCH_ROOT : lien vers / avec dash, ou racine BusyBox ash, ou racine bash). Rien sur la camera.
HERE=$(cd "$(dirname "$0")" && pwd)
export QP_DIST=${QP_DIST:-$HERE/../dist}
. "$HERE/lib.sh"
A=$T/qp/state; R=$T/run
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "SSH_SECOURS_PORT=2222" "$@" > $T/qp/guard.conf; }
PIDF=/tmp/qptest/dropbear-2222.pid
guard8() { run "$ENVV QP_DROPBEAR=/tmp/qptest/dropbear QP_DROPBEAR_PID=$PIDF QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=sleep QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
order() { mkdir -p $R/cmd; : > $R/cmd/$1; }
# faux processus d'ecoute dropbear (meme nom de processus qu'un vrai : script nomme dropbear, comme le faux hlcamd de test-v7)
fakedropbear() { mkdir -p $T/dbr; printf '#!/bin/sh\nsleep 300\n' > $T/dbr/dropbear; chmod +x $T/dbr/dropbear
  chroot $ROOT /tmp/qptest/dbr/dropbear & DP=$!; sleep 0.5; echo $DP > $T/dropbear-2222.pid; }
killdbr() { kill $DP 2>/dev/null; wait $DP 2>/dev/null; pkill -P $DP 2>/dev/null; }
nrelance() { grep -c 'dropbear -s -g -p 2222 -K 30 -P /tmp/qptest/dropbear-2222.pid' $T/calls; }

echo "S1 : dropbear 2222 absent -> relance avec maintien de connexion (-K 30) et fichier pid"
reset; conf; printf 'tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN\n' > $T/listen
printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n' > $T/net_tcp
ONCE=1 guard8 >/dev/null 2>&1
[ "$(nrelance)" = 1 ] && ok "dropbear 2222 relance avec -K 30" || { ko "relance : $(grep dropbear $T/calls)"; }
grep -q "SSH de secours (port 2222) absent : relance" $T/log && ok "relance journalisee" || ko "pas de journal"
! grep -q "restart dropbear" $T/calls && ok "dropbear 22 (present) non touche" || ko "dropbear 22 relance a tort"

echo "S2 : ordre ssh-restart -> arret du dropbear 2222 (processus verifie par son nom), relance des deux ecoutes"
reset; conf; fakedropbear; order ssh-restart
ONCE=1 guard8 >/dev/null 2>&1; sleep 1.5
kill -0 $DP 2>/dev/null && ko "ancien dropbear 2222 encore vivant" || ok "ancien dropbear 2222 arrete"
[ "$(nrelance)" = 1 ] && ok "dropbear 2222 relance (-K 30)" || ko "relance 2222 : $(nrelance)"
grep -q "fbxupstartctl restart dropbear" $T/calls && ok "dropbear 22 relance par fbxupstartctl" || ko "dropbear 22 non relance"
grep -q "ordre HA : relance SSH" $T/log && grep -q "dropbear 22 et 2222 relances (ordre HA)" $T/log && ok "ordre et relance journalises" || ko "journal : $(grep -i ssh $T/log)"
[ ! -e $R/cmd/ssh-restart ] && ok "ordre consomme" || ko "ordre reste"
killdbr

echo "S3 : numero de processus perime (un autre programme) -> aucun arret, relance quand meme"
reset; conf; chroot $ROOT /bin/sleep 300 & OP=$!; sleep 0.3; echo $OP > $T/dropbear-2222.pid; order ssh-restart
ONCE=1 guard8 >/dev/null 2>&1; sleep 1.5
kill -0 $OP 2>/dev/null && ok "processus sans rapport laisse en vie" || ko "processus sans rapport tue"
[ "$(nrelance)" = 1 ] && ok "dropbear 2222 relance" || ko "relance : $(nrelance)"
grep -q "numero $OP perime (processus sleep)" $T/log && ok "numero perime journalise" || ko "journal : $(grep perime $T/log)"
kill $OP 2>/dev/null; wait $OP 2>/dev/null
reset; conf; echo 99999 > $T/dropbear-2222.pid; order ssh-restart
ONCE=1 guard8 >/dev/null 2>&1; sleep 1.5
[ "$(nrelance)" = 1 ] && grep -q "perime (processus absent)" $T/log && ok "numero absent : relance, journalise" || ko "numero absent : $(nrelance) $(grep perime $T/log)"

echo "S4 : 6 relances SSH par heure au plus ; ordre inconnu ignore"
reset; conf
for i in 1 2 3 4 5 6 7; do order ssh-restart; ONCE=1 guard8 >/dev/null 2>&1; done
[ "$(nrelance)" = 6 ] && ok "6 relances sur 7 ordres" || ko "relances : $(nrelance)"
grep -q "ordre HA refuse (6 relances SSH par heure au plus) : ssh-restart" $T/log && ok "refus journalise" || ko "pas de refus"
reset; conf; order ssh-reboot
ONCE=1 guard8 >/dev/null 2>&1
grep -q "ordre inconnu ignore : ssh-reboot" $T/log && [ "$(nrelance)" = 0 ] && ok "ordre hors liste ignore" || ko "ordre hors liste : $(nrelance)"

echo "S5 : mode passif -> rien n'est fait, l'intention est journalisee"
reset; conf PASSIVE=1; order ssh-restart
ONCE=1 guard8 >/dev/null 2>&1
[ "$(nrelance)" = 0 ] && ! grep -q "restart dropbear" $T/calls && grep -q "(passif, non fait) relance de dropbear 22 et 2222 (ordre HA)" $T/log && ok "passif respecte" || ko "passif : $(grep -c dropbear $T/calls) appels, $(grep passif $T/log)"

echo "S6 : codec video demande a hlcamd dans le relevé (video_codec)"
fakehl() { printf '#!/bin/sh\nsleep 30\n' > $T/hlcamd; chmod +x $T/hlcamd; chroot $ROOT /tmp/qptest/hlcamd -d 75 --iv-detection 0 "$@" --1080p-bitrate 1500000 --gop-denum 2 & HP=$!; sleep 0.5; }
killhl() { kill $HP 2>/dev/null; wait $HP 2>/dev/null; pkill -P $HP 2>/dev/null; }
for cod in h264 h265; do   # pas « c » : reset (lib.sh) s'en sert
  reset; conf; fakehl --use-$cod; ONCE=1 guard8 >/dev/null 2>&1; killhl
  grep -q "^video_codec=$cod\$" $R/guard-status && ok "--use-$cod -> video_codec=$cod" || ko "video_codec : $(grep video_codec $R/guard-status)"
done
reset; conf; fakehl; ONCE=1 guard8 >/dev/null 2>&1; killhl
grep -q '^video_codec=defaut$' $R/guard-status && ok "sans option -> video_codec=defaut" || ko "video_codec : $(grep video_codec $R/guard-status)"
reset; conf; ONCE=1 guard8 >/dev/null 2>&1
grep -q '^video_codec=absent$' $R/guard-status && grep -q '^video_iv=absent$' $R/guard-status && ok "hlcamd absent -> video_codec=absent" || ko "video_codec : $(grep video_codec $R/guard-status)"

echo "S7 : le surveillant ne lit aucun compteur ICMP ni ping entrant (la puce Wi-Fi repond seule aux pings)"
! grep -qiE 'icmp|/proc/net/snmp' <(sed -n '/^video_check()/,$p' $QP_DIST/qp-guard | grep -v '^#' | grep -v snapshot) && ok "aucune lecture ICMP dans la boucle" || ko "lecture ICMP trouvee"
grep -q 'ping -c 1 -W 2 "\$GW"' $QP_DIST/qp-guard && ok "seul le ping sortant vers la passerelle juge le reseau" || ko "ping de la passerelle absent"

echo "S8 (v9) : une commande externe qui ne rend pas la main ne fige plus le surveillant (fbxupstartctl bloque 60 s -> arretee a 20 s)"
reset; conf; order ssh-restart
printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\ncase "$*" in "restart dropbear") exec sleep 60;; esac\n' > $T/stubs/fbxupstartctl
t0=$(date +%s); ONCE=1 guard8 >/dev/null 2>&1; dt=$(( $(date +%s) - t0 ))
[ "$dt" -lt 40 ] && ok "surveillant rendu en $dt s (bloquant evite)" || ko "surveillant bloque $dt s"
grep -q "commande sans reponse apres 20 s, arretee : fbxupstartctl restart" $T/log && ok "commande bloquee journalisee et arretee" || ko "journal : $(grep -i reponse $T/log)"
grep -q "dropbear 22 et 2222 relances (ordre HA) : ecoute 22=" $T/log && ok "etat des ecoutes journalise apres la relance" || ko "journal : $(grep relances $T/log)"

echo "S9 (v9) : ancien dropbear 2222 qui ignore TERM -> arrete de force apres 5 s, puis relance"
reset; conf; mkdir -p $T/dbr; printf '#!/bin/sh\ntrap "" TERM\nwhile :; do sleep 1; done\n' > $T/dbr/dropbear; chmod +x $T/dbr/dropbear   # le nom de processus reste dropbear ; ses sleep d'une seconde ne laissent pas d'orphelin
chroot $ROOT /tmp/qptest/dbr/dropbear & DP=$!; sleep 0.5; echo $DP > $T/dropbear-2222.pid; order ssh-restart
ONCE=1 guard8 >/dev/null 2>&1; sleep 1
kill -0 $DP 2>/dev/null && ko "ancien dropbear 2222 (sourd a TERM) encore vivant" || ok "ancien dropbear 2222 arrete de force"
grep -q "ancien processus $DP arrete de force" $T/log && ok "arret force journalise" || ko "journal : $(grep force $T/log)"
[ "$(nrelance)" = 1 ] && ok "dropbear 2222 relance" || ko "relance : $(nrelance)"
killdbr

echo "S10 (distribution) : SSH de secours non configure (defaut) -> aucun dropbear lance, etat « off », ssh-restart ne relance que le 22"
reset; printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" > $T/qp/guard.conf
printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n' > $T/net_tcp
ONCE=1 guard8 >/dev/null 2>&1
[ "$(grep -c 'dropbear -s -g' $T/calls)" = 0 ] && ok "aucun dropbear de secours lance" || ko "dropbear lance : $(grep dropbear $T/calls)"
grep -q '^ssh2222=off$' $R/guard-status && grep -q '^ssh22=1$' $R/guard-status && ok "etat ssh22=1 ssh2222=off" || ko "etat : $(grep ssh $R/guard-status)"
order ssh-restart; ONCE=1 guard8 >/dev/null 2>&1
grep -q "restart dropbear" $T/calls && [ "$(grep -c 'dropbear -s -g' $T/calls)" = 0 ] && ok "ssh-restart : 22 relance, pas de secours" || ko "appels : $(grep dropbear $T/calls)"
echo "S11 (distribution) : port de secours personnalise (2022)"
reset; printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "SSH_SECOURS_PORT=2022" > $T/qp/guard.conf
printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n' > $T/net_tcp
ONCE=1 guard8 >/dev/null 2>&1
grep -q 'dropbear -s -g -p 2022 -K 30' $T/calls && ok "dropbear lance sur 2022" || ko "appels : $(grep dropbear $T/calls)"
printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n   1: 00000000:07E6 00000000:0000 0A 0\n' > $T/net_tcp; : > $T/calls
ONCE=1 guard8 >/dev/null 2>&1
grep -q '^ssh2222=1$' $R/guard-status && [ "$(grep -c 'dropbear -s -g' $T/calls)" = 0 ] && ok "ecoute 2022 reconnue (07E6), pas de relance" || ko "etat : $(grep ssh $R/guard-status) ; appels : $(grep -c dropbear $T/calls)"

summary
