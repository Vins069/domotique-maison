# lib.sh - outils communs des essais a blanc (banc d'essai : shell reel de la camera, chroot ARM sous qemu).
ROOT=${QP_BENCH_ROOT:-/tmp/camroot}
# dist/ a essayer : QP_DIST, sinon le dist/ a cote de ce fichier (les suites sont des scripts bash : BASH_SOURCE)
QP_DIST=${QP_DIST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist}; export QP_DIST
RROOT=$(readlink -f "$ROOT")   # racine reelle (le banc peut etre un lien vers /)
T=$ROOT/tmp/qptest
fail=0; n=0
ok()  { n=$((n+1)); echo "  ok   : $1"; }
ko()  { n=$((n+1)); fail=$((fail+1)); echo "  ECHEC: $1"; }
run() { chroot $ROOT /bin/sh -c "$*" ; }
# environnement commun : tout sous /tmp/qptest, jamais /data ni /media reels
ENVV="QP=/tmp/qptest/qp QP_BULK=/tmp/qptest/bulk QP_RUN=/tmp/qptest/run QP_LOG=/tmp/qptest/log QP_NO_OLD=1 PATH=/tmp/qptest/stubs:/bin:/sbin:/usr/bin:/usr/sbin"
reset() {
  rm -rf $T; mkdir -p $T/qp $T/bulk $T/run $T/stubs
  for f in launch update guard; do cp $QP_DIST/qp-$f $T/qp-$f; chmod +x $T/qp-$f; done
  cp $T/qp-update $T/qp/qp-update
  : > $T/log
  # bouchons : commandes systeme de la camera
  for c in fbxbusctl fbxupstartctl reboot; do printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\n' > $T/stubs/$c; chmod +x $T/stubs/$c; done
  printf '#!/bin/sh\nif [ -e /tmp/qptest/net_down ]; then exit 1; fi\nexit 0\n' > $T/stubs/ping; chmod +x $T/stubs/ping
  printf '#!/bin/sh\ncat /tmp/qptest/listen 2>/dev/null\n' > $T/stubs/netstat; chmod +x $T/stubs/netstat
  printf 'tcp 0 0 0.0.0.0:2222 0.0.0.0:* LISTEN\ntcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN\n' > $T/listen
  printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n   1: 00000000:08AE 00000000:0000 0A 0\n' > $T/net_tcp
  printf '#!/bin/sh\necho 192.0.2.254\n' > $T/stubs/gwhelper
  printf '#!/bin/sh\necho "default via 192.0.2.254 dev ssv0"\n' > $T/stubs/ip; chmod +x $T/stubs/ip
  printf '#!/bin/sh\necho "$0 $*" >> /tmp/qptest/calls\n' > $T/dropbear; chmod +x $T/dropbear
  : > $T/calls
}
# mk slot "corps du script" : cree un faux binaire (script) avec empreinte
mk() {
  d=$T/bulk/slots/$1; [ "$1" = factory ] && d=$T/qp/slots/factory
  mkdir -p $d; printf '#!/bin/sh\n%s\n' "$2" > $d/openqiarad; chmod +x $d/openqiarad
  run "sha256sum /tmp/qptest/$( [ $1 = factory ] && echo qp/slots/factory || echo bulk/slots/$1 )/openqiarad | cut -d' ' -f1 > /tmp/qptest/$( [ $1 = factory ] && echo qp/slots/factory || echo bulk/slots/$1 )/openqiarad.sha256"
}
launch() { run "$ENVV ${BID:+QP_BOOT_ID=$BID} QP_STABLE_SEC=${STABLE:-2} QP_GAP_SEC=0 QP_MAXFAIL=3 QP_NOBIN_SLEEP=1 /tmp/qptest/qp-launch -web :80 -log /x" ; }
upd()    { run "$ENVV QP_APP_COMM=${APPCOMM:-sleep} QP_MIN_SIZE=${MINSZ:-1000000} /tmp/qptest/qp/qp-update $*" ; }
guard()  { run "$ENVV QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_APP_COMM=${APPCOMM:-sleep} QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=${ONCE:-1} /tmp/qptest/qp-guard" ; }
# faux ELF ARM de la taille voulue (en-tete reel : 7f45 4c46, classe 32 bits, machine 0x28)
fake_elf() { # fake_elf fichier taille_octets
  printf '\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00' > "$1"
  head -c $(( $2 - 20 )) /dev/urandom >> "$1"
}
summary() { echo; echo "=== $n controles, $fail echec(s) ==="; [ $fail = 0 ]; }
