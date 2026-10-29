#!/bin/sh
# Lanceur d'OpenQiara a trois emplacements (Claude, 26/10/2026, v2 ; v6 27/10 : numero de demarrage, app.env verifie,
# factory relance sans app.env apres MAXFAIL arrets rapides, empreinte de l'essai notee dans le marqueur).
# Installe sous /data/openqiarad : la boucle de boot.sh le relance comme elle relancait le binaire.
# Il fait le bilan du lancement precedent, choisit le binaire (new, good ou factory), puis se REMPLACE par lui (exec) :
# aucun processus supplementaire ne reste en memoire, les signaux vont directement a l'application.
# Trois arrets rapides de suite (< QP_STABLE_SEC, meme demarrage) marquent l'emplacement BAD et font passer au suivant.
# Un essai (new) est aussi ecarte s'il a ete lance plus de QP_MAXSTART fois sans etre valide (boucle de redemarrages).
QP_WHO=qp-launch
QP=${QP:-/data/qp}
#@INCLUDE common.sh
STABLE=$(int "${QP_STABLE_SEC:-120}" 120)
GAP=$(int "${QP_GAP_SEC:-15}" 15)            # pause de la boucle de boot.sh entre deux lancements (10 s) + marge
MAXFAIL=$(int "${QP_MAXFAIL:-3}" 3)
MAXSTART=$(int "${QP_MAXSTART:-6}" 6)
boot_id; up_now
boot_seq_bump          # v6 : numero de demarrage (une ecriture par demarrage, seulement si le demarrage a change)

# Verrou : un seul lanceur (puis une seule application, qui herite du pid) a la fois.
LOCK=$RUN/launch.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  rd op "$LOCK/pid" 0
  [ "$op" = 0 ] && { sleep 1; rd op "$LOCK/pid" 0; }      # v5 : verrou en cours de creation (pid pas encore ecrit) : ne pas le voler
  if [ "$op" != 0 ] && kill -0 "$op" 2>/dev/null; then sleep 5; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 1
fi
echo $$ > "$LOCK/pid"

# 1. Bilan du lancement precedent (seulement s'il a eu lieu pendant ce demarrage)
rd pslot "$ST/running_slot" ""
rd pboot "$ST/run_boot" ""
rd pup "$ST/run_up" 0
fslot=; fails=0; [ -s "$ST/fails" ] && read -r fslot fails < "$ST/fails"
fails=$(int "$fails" 0); [ "$fslot" = "$pslot" ] || fails=0      # le compteur appartient a un emplacement
if [ -n "$pslot" ] && [ "$pboot" = "$BOOT" ]; then
  dur=$(( UP - $(int "$pup" 0) ))
  if [ -e "$ST/expected_stop" ]; then
    log "$pslot arrete volontairement apres ~${dur} s"; fails=0
  elif [ "$dur" -lt $((STABLE + GAP)) ]; then
    fails=$((fails + 1))
    log "$pslot s'est arrete apres ~${dur} s : arret rapide $fails/$MAXFAIL"
    if [ "$fails" -ge "$MAXFAIL" ]; then
      if [ "$pslot" = factory ]; then
        # v6 : factory n'est jamais ecarte ; le compteur continue et, tant qu'il reste au plafond, l'application est lancee
        # SANS app.env (un reglage Go invalide, GOMEMLIMIT par exemple, arrete l'execution Go au demarrage, pour toutes les versions)
        log "factory : $fails arrets rapides, prochain lancement sans app.env"
      else
        [ "$pslot" != media-old ] && mark_bad "$pslot"
        if [ "$pslot" = new ]; then rm -f "$ST/trial"; put "$ST/new_starts" 0; result "echec: new plante au demarrage, retour a good"; fi
        fails=0
      fi
    fi
  else
    log "$pslot s'est arrete apres ~${dur} s"; fails=0
  fi
fi
put "$ST/fails" "$pslot $fails"
rm -f "$ST/expected_stop"

# 2. Choix de l'emplacement
rd active "$ST/active" good
chosen=; BIN=
for s in $(order "$active"); do
  if slot_valid "$s"; then
    if [ "$s" = new ]; then
      rd ns "$ST/new_starts" 0; ns=$(( $(int "$ns" 0) + 1 ))
      if [ "$ns" -gt "$MAXSTART" ]; then
        log "new lance $((ns-1)) fois sans validation : ecarte (boucle de redemarrages ?)"
        mark_bad new; put "$ST/new_starts" 0; rm -f "$ST/trial"
        result "echec: new ecarte apres $((ns-1)) lancements sans validation"
        continue
      fi
      put "$ST/new_starts" "$ns"
    fi
    chosen=$s; break
  fi
  log "emplacement $s inutilisable, essai du suivant"
done
if [ -z "$chosen" ]; then
  # v6 : si une empreinte accompagne la copie de secours (ecrite par qp-update), elle doit correspondre ; sans empreinte, la copie
  # d'origine (24/10, anterieure a Qiara Plus) est acceptee telle quelle, comme avant.
  oldok=0
  if [ -s "$OLD" ]; then
    oldok=1; VSHA=$(sha_of "$OLD")
    if [ -s "$OLD.sha256" ]; then _ow=; read -r _ow _ox < "$OLD.sha256"; [ "$_ow" = "$VSHA" ] || { oldok=0; log "copie de secours $OLD : empreinte differente de $OLD.sha256, ignoree"; }; fi
  fi
  if [ "$oldok" = 1 ]; then
    log "aucun emplacement valide, repli sur $OLD"
    BIN=$OLD; chosen=media-old
  else
    log "AUCUN binaire utilisable, nouvel essai dans 30 s"
    rm -rf "$LOCK"; sleep "${QP_NOBIN_SLEEP:-30}"; exit 1
  fi
else
  BIN=$(sd "$chosen")/openqiarad
fi
# Un essai (new) inutilisable met fin a l'essai : retour durable a good. Un repli depuis good ou prev reste
# temporaire : l'emplacement actif ne change pas, il sera retente au prochain lancement (marquage BAD expire).
if [ "$active" = new ] && [ "$chosen" != new ]; then
  put "$ST/active" good; put "$ST/new_starts" 0
  if [ -e "$ST/trial" ]; then rm -f "$ST/trial"; result "echec: new inutilisable, retour a good"; fi
  log "essai abandonne (new inutilisable) : emplacement actif good, lance : $chosen"
elif [ "$chosen" != "$active" ]; then
  log "repli temporaire sur $chosen ($active inutilisable)"
fi
# v4.1 : un essai dont le marqueur a disparu (ecriture perdue par la carte SD lors de la panne du 26/10 a 20 h 28 :
# active=new est reste, trial non) ne serait jamais valide ni annule par le surveillant. Le marqueur est recree :
# l'essai reprend ses regles (validation apres 3 min de bonne sante, retour arriere sur blocages, 6 lancements au plus).
if [ "$chosen" = new ] && [ ! -e "$ST/trial" ]; then
  put "$ST/trial" "$(now) $VSHA"; sync
  log "marqueur d'essai absent pour new (ecriture perdue ?) : recree, l'essai continue"
  result "essai en cours : $(echo "$VSHA" | cut -c1-12) (marqueur recree)"
fi
[ -x "$BIN" ] || chmod 755 "$BIN" 2>/dev/null

# 3. Reglages de l'execution Go (memoire) : seules quelques variables connues sont acceptees, avec une valeur de forme connue
# (v6 : un GOMEMLIMIT mal forme fait sortir l'execution Go des le demarrage ; un fichier abime ne doit pas rendre toutes les
# versions inlancables). Apres MAXFAIL arrets rapides de factory, le fichier est ignore en entier.
noenv=0; [ "$chosen" = factory ] && [ "$pslot" = factory ] && [ "$fails" -ge "$MAXFAIL" ] && noenv=1
if [ -s "$QP/app.env" ] && [ "$noenv" = 0 ]; then
  while IFS='=' read -r k v; do
    [ -n "$v" ] || continue
    ok=0
    case "$k" in
      GOGC)        case "$v" in off|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ok=1;; esac ;;
      GOMEMLIMIT)  case "$v" in off) ok=1;; *[!0-9A-Za-z]*) ;; [0-9]*) case "${v#"${v%%[!0-9]*}"}" in ''|B|KiB|MiB|GiB|TiB|KB|MB|GB|TB) ok=1;; esac;; esac ;;
      GOMAXPROCS)  case "$v" in [1-9]|[1-9][0-9]) ok=1;; esac ;;
      GOTRACEBACK) case "$v" in none|single|all|system|crash) ok=1;; esac ;;
      GODEBUG)     case "$v" in *[!A-Za-z0-9_,=.-]*) ;; *) ok=1;; esac ;;
    esac
    if [ "$ok" = 1 ]; then export "$k=$v"; else log "app.env : ligne refusee ($(echo "$k" | cut -c1-20)=$(echo "$v" | cut -c1-20))"; fi
  done < "$QP/app.env"
elif [ "$noenv" = 1 ]; then log "app.env ignore (factory arrete $fails fois de suite)"
fi

# 4. Surveillance mutuelle : si le surveillant ne tourne plus, le lanceur le relance (il relance l'application, et inversement)
if [ -f "$QP/qp-guard" ] && [ -z "$QP_NO_GUARD" ]; then
  rd gp "$RUN/guard.lock/pid" 0
  if [ "$gp" = 0 ] || ! kill -0 "$gp" 2>/dev/null; then
    log "surveillant absent : relance"
    ( nohup sh "$QP/qp-guard" >/dev/null 2>&1 & )
  fi
fi

# 5. Etat, puis remplacement par l'application (meme pid)
put "$ST/running_slot" "$chosen"; put "$ST/run_boot" "$BOOT"; put "$ST/run_up" "$UP"; put "$ST/child" "$$"
rm -f "$RUN/health"     # la sante ecrite par un lancement precedent ne doit jamais etre jugee pour celui-ci
log "demarrage de $chosen ($(echo "$VSHA" | cut -c1-12))${GOGC:+ GOGC=$GOGC}${GOMEMLIMIT:+ GOMEMLIMIT=$GOMEMLIMIT}"
# QP_EXEC_SH : seulement pour l'essai a blanc sur la camera, ou /tmp interdit l'execution (noexec) : le faux binaire y est lu par sh.
if [ -n "$QP_EXEC_SH" ]; then exec sh "$BIN" "$@"; fi
exec "$BIN" "$@"
