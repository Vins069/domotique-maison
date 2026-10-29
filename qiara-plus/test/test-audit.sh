#!/bin/bash
# Essais a blanc des correctifs de l'audit du 26/10/2026 (chroot ARM sous qemu). Aucune ecriture sur la camera.
. "$(dirname "$0")/lib.sh"
A=$T/qp/state; R=$T/run; S=$T/bulk/slots
conf() { printf '%s\n' "TICK=1" "NET_CHECK_SEC=1" "SLOW_SEC=1" "GATEWAY=192.0.2.254" "$@" > $T/qp/guard.conf; }
upt() { read -r u _ < /proc/uptime; echo ${u%%.*}; }
bid() { cat /proc/sys/kernel/random/boot_id; }
fakechild() { # faux processus applicatif lance il y a $1 s, dans l'emplacement $2
  mkdir -p $A $R; chroot $ROOT /bin/sleep 300 & CH=$!; sleep 0.5
  echo $CH > $A/child; echo ${2:-good} > $A/running_slot; echo $(( $(upt) - ${1:-400} )) > $A/run_up; bid > $A/run_boot
}
killchild() { kill $CH 2>/dev/null; wait $CH 2>/dev/null; }
# sante : health mqtt app_ok age_s [mqtt_broker]
health() { { printf 'ts=%s\nup=%s\napp_ok=%s\n' "$(date +%s)" "$(( $(upt) - ${3:-0} ))" "${2:-1}"; [ -n "$1" ] && echo "mqtt=$1"; [ -n "$4" ] && echo "mqtt_broker=$4"; } > $R/health; }
seed3() { fake_elf $T/orig.bin 1500000; fake_elf $T/cur.bin 1400000; fake_elf $T/new.bin 1600000
  upd seed-factory /tmp/qptest/orig.bin >/dev/null; upd seed-good /tmp/qptest/cur.bin >/dev/null; upd stage /tmp/qptest/new.bin >/dev/null; }
alive() { kill -0 $CH 2>/dev/null; }

echo "A1 : sante laissee par une version precedente (avant ce lancement) -> la version actuelle n'est pas arretee"
reset; conf HEALTH_GRACE=1 HEALTH_STALE=5; fakechild 400 good; health 1 1 1000   # ecrite 1000 s avant, lancement il y a 400 s
ONCE=3 guard >/dev/null 2>&1; sleep 1
alive && ok "version sans fichier de sante laissee tranquille (sante perimee ignoree)" || ko "version saine arretee a cause d'une vieille sante"
killchild

echo "A2 : essai qui n'ecrit aucune sante -> blocage constate, puis retour arriere"
reset; seed3; conf HEALTH_GRACE=1 TRIAL_HANG_MAX=1; fakechild 400 new; rm -f $R/health
ONCE=1 guard >/dev/null 2>&1; sleep 1
! alive && [ -e $S/new/BAD ] && [ "$(cat $A/active)" = good ] && [ ! -e $A/trial ] && ok "essai muet arrete et annule" || ko "essai muet non traite"
grep -q "aucune sante" $T/log && ok "raison journalisee" || ko "raison absente"
killchild

echo "A3 : version qui ecrivait sa sante et n'en ecrit plus -> arret, au plus HANG_MAX_HOUR par heure"
reset; conf HEALTH_GRACE=1 HANG_MAX_HOUR=2; mkdir -p $S/good; : > $S/good/HEALTH_SEEN
for i in 1 2 3; do fakechild 400 good; rm -f $R/health; ONCE=1 guard >/dev/null 2>&1; sleep 1; alive && r[$i]=vivant || r[$i]=arrete; killchild; done
[ "${r[1]}" = arrete ] && [ "${r[2]}" = arrete ] && [ "${r[3]}" = vivant ] && ok "2 arrets puis plus rien (limite horaire)" || ko "limite horaire : ${r[*]}"
grep -q "deja 2 arrets en 1 h" $T/log && ok "limite journalisee" || ko "limite non journalisee"

echo "A4 : la sante d'une version saine marque l'emplacement (HEALTH_SEEN)"
reset; conf; mkdir -p $S/good; fakechild 400 good; health 1 1
ONCE=1 guard >/dev/null 2>&1
[ -e $S/good/HEALTH_SEEN ] && ok "marque posee" || ko "marque absente"
killchild

echo "A5 : MQTT coupe : relance seulement si le serveur MQTT repond, 2 fois par heure au plus"
reset; conf MQTT_RESTART_SEC=1; fakechild 400 good; health 0 1 0 0
ONCE=4 guard >/dev/null 2>&1; sleep 1
alive && ok "serveur MQTT injoignable : aucune relance (Home Assistant arrete)" || ko "relance inutile pendant une panne de HA"
killchild
reset; conf MQTT_RESTART_SEC=1; fakechild 400 good; health 0 1 0
ONCE=4 guard >/dev/null 2>&1; sleep 1
alive && ok "etat du serveur inconnu (ancienne version) : aucune relance" || ko "relance sans preuve"
killchild
reset; conf MQTT_RESTART_SEC=1; n2=0
for i in 1 2 3; do fakechild 400 good; health 0 1 0 1; ONCE=4 guard >/dev/null 2>&1; sleep 1; alive || n2=$((n2+1)); killchild; done
[ "$n2" = 2 ] && ok "serveur joignable : relance, limitee a 2 par heure" || ko "relances MQTT : $n2 au lieu de 2"

echo "A6 : validation d'un essai : attend la liaison MQTT"
reset; seed3; conf PROMOTE_AFTER=1; fakechild 400 new; health 0 1
ONCE=1 guard >/dev/null 2>&1
[ -e $A/trial ] && ok "pas de validation tant que mqtt=0" || ko "validation sans MQTT"
health 1 1; ONCE=1 guard >/dev/null 2>&1
[ ! -e $A/trial ] && [ "$(cat $A/active)" = good ] && ok "validation des que mqtt=1" || ko "pas de validation avec mqtt=1"
killchild
reset; seed3; conf PROMOTE_AFTER=1; fakechild 400 new; health "" 1
ONCE=1 guard >/dev/null 2>&1
[ ! -e $A/trial ] && ok "sans courtier configure (pas de ligne mqtt) : validation" || ko "validation bloquee sans courtier"
killchild

echo "A7 : /data/openqiarad remplace (mise a jour par l'interface) -> le surveillant ne lance plus rien"
reset; conf DEAD_SEC=1; mkdir -p $A; fake_elf $T/launcher 1100000; chmod +x $T/launcher
run "$ENVV QP_LAUNCHER=/tmp/qptest/launcher QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=4 /tmp/qptest/qp-guard" >/dev/null 2>&1
grep -q "n'est plus le lanceur" $T/log && ok "aucun second OpenQiara lance, raison journalisee" || ko "lancement d'un binaire qui n'est pas le lanceur"
grep -q '^launcher_ok=0' $R/guard-status && ok "etat launcher_ok=0" || ko "etat launcher_ok absent"

echo "A8 : application lancee depuis le repli ultime (nom openqiarad.old) reconnue vivante"
reset; conf DEAD_SEC=1; mkdir -p $A; cp $ROOT/bin/bash $T/openqiarad.old
chroot $ROOT /tmp/qptest/openqiarad.old -c 'sleep 30; :' & CH=$!; sleep 0.5; echo $CH > $A/child; echo media-old > $A/running_slot
printf '#!/bin/sh\necho lance >> /tmp/qptest/launched\n' > $T/launcher; chmod +x $T/launcher
run "$ENVV QP_LAUNCHER=/tmp/qptest/launcher QP_APP_COMM=openqiarad QP_DROPBEAR=/tmp/qptest/dropbear QP_SYSRQ=/tmp/qptest/sysrq QP_NET_TCP=/tmp/qptest/net_tcp QP_ONCE=4 /tmp/qptest/qp-guard" >/dev/null 2>&1
[ ! -s $T/launched ] && ok "openqiarad.old reconnu : pas de second lancement" || ko "second lancement a tort"
killchild

echo "A9 : robustesse du surveillant : dossier d'etat disparu, fichiers corrompus"
reset; conf; fakechild 400 good; mkdir -p $R/cmd; : > $R/cmd/restart-app; printf '12x 08 abc\n' > $A/rate_reboot; printf 'ts=12x\nup=0x1\napp_ok=1\n' > $R/health
mkdir -p $A/expected_stop          # ecriture impossible (meme pour root) : "Is a directory"
ONCE=3 guard >/dev/null 2>&1; rc=$?
rmdir $A/expected_stop
grep -c "surveillant demarre" $T/log >/dev/null; [ $(grep -c '^ts=' $R/guard-status 2>/dev/null || echo 0) -ge 1 ] && ok "surveillant toujours vivant apres ecriture impossible et valeurs corrompues" || ko "surveillant arrete (rc=$rc)"
killchild

echo "A10 : retour arriere demande sans essai en cours -> ignore"
reset; seed3; upd promote --force >/dev/null 2>&1; echo prev > $A/active
upd rollback "ordre HA" >/dev/null 2>&1
[ "$(cat $A/active)" = prev ] && [ ! -e $S/new/BAD ] && grep -q "rien a annuler" $R/last_update_result && ok "aucun effet, raison indiquee" || ko "retour arriere sans essai a modifie l'etat ($(cat $A/active))"

echo "A11 : place necessaire = taille + reserve (et non deux fois la taille) ; lien physique pour factory"
reset; fake_elf $T/b.bin 1500000
run "$ENVV QP_FAKE_FREE=6000 /tmp/qptest/qp/qp-update seed-good /tmp/qptest/b.bin" >/dev/null 2>&1 && ok "1,5 Mo avec 6 Mio libres : accepte" || ko "refuse a tort (calcul de place)"
run "$ENVV QP_FAKE_FREE=5000 /tmp/qptest/qp/qp-update seed-good /tmp/qptest/b.bin" >/dev/null 2>&1 && ko "accepte sans la reserve" || ok "refuse sans la reserve de 4 Mio"
run "$ENVV QP_FAKE_FREE=10 /tmp/qptest/qp/qp-update seed-factory /tmp/qptest/b.bin" >/dev/null 2>&1
i1=$(stat -c %i $T/b.bin); i2=$(stat -c %i $T/qp/slots/factory/openqiarad 2>/dev/null)
[ "$i1" = "$i2" ] && ok "factory = lien physique (meme inode, aucune place consommee)" || ko "factory copie ($i1/$i2)"
run "$ENVV /tmp/qptest/qp/qp-update status" | grep -q "slot_factory=.* valid=1" && ok "factory valide" || ko "factory invalide"

echo "A12 : remplacement d'un emplacement : la marque HEALTH_SEEN disparait"
mkdir -p $S/good; : > $S/good/HEALTH_SEEN; run "$ENVV /tmp/qptest/qp/qp-update seed-good /tmp/qptest/b.bin" >/dev/null 2>&1
[ ! -e $S/good/HEALTH_SEEN ] && ok "marque retiree avec l'ancien binaire" || ko "marque conservee a tort"

summary
