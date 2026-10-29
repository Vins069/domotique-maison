#!/bin/sh
# services-cloud.sh : services du cloud Qiara (serveurs arretes) neutralises A LA SOURCE, ou remis d'origine.
#   sh services-cloud.sh liste         montre les declencheurs des fiches concernees, ne touche a rien ;
#   sh services-cloud.sh neutraliser   leurs fiches /etc/fbxupstart.d (partition systeme, en lecture seule) perdent leurs
#                                      declencheurs (lignes signals et event.*, mises en commentaire) : ces services ne
#                                      demarrent plus. Copie de securite de toutes les fiches, jamais ecrasee ;
#   sh services-cloud.sh retour        remet les fiches d'origine depuis la copie de securite.
# Effet complet au prochain redemarrage. Sans cette etape, boot.sh arrete ces services a chaque demarrage (toutes les
# 30 s) : la neutralisation evite seulement qu'ils demarrent pour rien.
# Neutralises : downloader, srt-daemon, hls-1080p, hls-720p, hls-360p, fbxhome, hl-event-collectd, nginx-pub, dnsmasq
# (celui du constructeur ; boot.sh lance le sien). CONSERVES volontairement : myriadvpn, hlsystem et watchdog (le chien de
# garde du constructeur en depend tant qu'OpenQiara ne l'a pas pris en main), hlbringup et hlconnman (Wi-Fi), charmux,
# fbxntp, dropbear, ens160, ttylog, uartboot, hlcamd.
# Ecriture sur la partition systeme : remount en ecriture puis lecture seule, retabli meme en cas d'interruption.
set -u
D=${SVC_D:-/etc/fbxupstart.d}; MNT=${SVC_MOUNT:-mount}
S=${SVC_S:-/media/oqc/sauvegarde/services-cloud}
MARK="-- neutralise par OpenQIARA Claude V15 (cloud Qiara arrete) :"
INERTES="downloader srt-daemon hls-1080p hls-720p hls-360p fbxhome hl-event-collectd nginx-pub dnsmasq"
RW=0
fin() { if [ "$RW" = 1 ]; then sync; $MNT -o remount,ro / && echo "partition systeme de nouveau en lecture seule" || echo "ATTENTION : remount ro en echec (sera en lecture seule au redemarrage)"; fi; [ -n "${T:-}" ] && rm -rf "$T"; }
trap fin EXIT
T=

case "${1:-}" in
liste)
  for s in $INERTES; do echo "-- $s ($(ls -l "$D/$s" 2>/dev/null | cut -c1-10))"; grep -nE '^[[:space:]]*(signals|event\.)' "$D/$s"; done
  ;;
neutraliser)
  echo "== neutralisation, debut $(date '+%Y-%m-%d %H:%M:%S')"
  [ -d "$S" ] && { echo "ECHEC : copie de securite deja presente ($S) : un passage a deja eu lieu, rien refait"; exit 1; }
  mkdir -p "$S/fbxupstart.d" || exit 1
  cp -p "$D"/* "$S/fbxupstart.d/" && sync && echo "$(ls "$S/fbxupstart.d" | wc -l) fiches copiees dans $S" || { echo "ECHEC : copie de securite impossible"; rm -rf "$S"; exit 1; }
  for s in $INERTES; do [ -f "$D/$s" ] && { cmp -s "$D/$s" "$S/fbxupstart.d/$s" || { echo "ECHEC : copie de securite differente : $s, abandon"; exit 1; }; }; done
  T=$(mktemp -d /tmp/svc.XXXXXX)
  $MNT -o remount,rw / || { echo "ECHEC : remount rw impossible : abandon, rien modifie"; exit 1; }
  RW=1
  for s in $INERTES; do
    f=$D/$s; [ -f "$f" ] || { echo "absent : $s"; continue; }
    sed -e "s|^\([[:space:]]*signals[[:space:]]*=.*\)$|$MARK \1|" -e "s|^\([[:space:]]*event\.[a-z_]*[[:space:]]*=.*\)$|$MARK \1|" "$f" > "$T/$s" || { echo "sed en echec : $s"; continue; }
    if grep -Eq '^[[:space:]]*(signals|event\.)' "$T/$s"; then echo "ATTENTION : declencheur restant dans $s"; fi
    if command -v luac >/dev/null 2>&1 && ! luac -p "$T/$s" >/dev/null 2>&1; then echo "ECHEC : fiche $s refusee par luac apres modification, non remplacee"; continue; fi
    if cmp -s "$f" "$T/$s"; then echo "inchange (aucun declencheur) : $s"
    else cp "$T/$s" "$f.tmp" && chmod 644 "$f.tmp" && mv -f "$f.tmp" "$f" && echo "neutralise : $s"; fi
  done
  sync
  for s in $INERTES; do [ -f "$D/$s" ] && printf '%-18s declencheurs actifs : %s\n' "$s" "$(grep -cE '^[[:space:]]*(signals|event\.)' "$D/$s")"; done
  echo "== fin $(date '+%H:%M:%S') ; effet complet au prochain redemarrage"
  ;;
retour)
  [ -d "$S/fbxupstart.d" ] && [ -n "$(ls "$S/fbxupstart.d" 2>/dev/null)" ] || { echo "copie de securite absente : rien fait"; exit 1; }
  $MNT -o remount,rw / || { echo "remount rw impossible"; exit 1; }
  RW=1
  for f in "$S"/fbxupstart.d/*; do n=$(basename "$f"); cp -p "$f" "$D/$n.tmp" && mv -f "$D/$n.tmp" "$D/$n" && echo "restaure : $n"; done
  sync
  mv "$S" "$S.restauree-$(date +%Y%m%d-%H%M%S)" && echo "copie de securite mise de cote : un nouveau passage du neutraliseur est possible"
  echo "effet complet au prochain redemarrage"
  ;;
*) echo "usage : sh services-cloud.sh liste|neutraliser|retour"; exit 2 ;;
esac
