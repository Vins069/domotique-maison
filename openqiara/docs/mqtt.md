# MQTT — Intégration Home Assistant

## Configuration

```json
{
  "mqtt": {
    "broker": "tcp://192.168.1.42:1883",
    "username": "openqiara",
    "password": "openqiara123",
    "topic_prefix": "openqiara"
  }
}
```

Si `broker` est vide, MQTT est désactivé et openqiarad tourne sans.

### TLS / mTLS

Pour chiffrer la connexion au broker, utiliser un schéma `ssl://` (ou `tls://`,
`mqtts://`) et le port TLS du broker (typiquement `8883`) :

```json
{
  "mqtt": {
    "broker": "ssl://192.168.1.42:8883",
    "username": "openqiara",
    "password": "openqiara123",
    "tls_ca_cert": "/data/mqtt/ca.pem",
    "tls_client_cert": "/data/mqtt/client.pem",
    "tls_client_key": "/data/mqtt/client.key",
    "tls_insecure": false
  }
}
```

- `tls_ca_cert` : chemin d'un bundle CA (PEM) pour valider le certificat du
  broker. Indispensable pour un broker auto-signé ou à CA privée (Mosquitto
  local). Absent → CA système, qui n'existent probablement pas sur la
  caméra : en pratique, à renseigner.
- `tls_client_cert` / `tls_client_key` : activent le **mTLS** (authentification
  par certificat client). Les deux sont requis ensemble.
- `tls_insecure` : désactive la vérification du certificat. **Test uniquement**,
  jamais en production.

Un fichier de certificat illisible ou invalide fait **échouer** le démarrage du
publisher MQTT (log `ERROR`) au lieu de retomber silencieusement en clair. Les
champs TLS ne sont lus qu'au démarrage : un redémarrage d'openqiarad est requis
pour les appliquer.

**Configuration par fichier uniquement.** Les champs `tls_*` se règlent dans
`openqiara.json` (avec les certificats sur le disque), **pas** via la web UI ni
l'API : le handler `PUT /api/v1/config/mqtt` les ignore, ce qui évite qu'un
formulaire web efface la configuration TLS ou repointe les certificats.

**Cohérence schéma/TLS.** Si un champ `tls_*` est renseigné mais que le broker
n'utilise pas un schéma TLS (`ssl://`, `tls://`, `mqtts://`, `mqtt+ssl://`,
`tcps://`, `wss://`), le publisher MQTT **ne démarre pas** (log `ERROR`, le reste
d'openqiarad tourne) au lieu de se connecter en clair — paho ignorerait sinon la
configuration TLS silencieusement. Pour la même raison, `PUT /api/v1/config/mqtt`
refuse (`400`) un broker sans schéma TLS quand des `tls_*` sont configurés.

## Auto-discovery HA

OpenQiara publie des configs auto-discovery sur les topics `homeassistant/...` au démarrage.

### DWS (binary_sensor)

```
Topic:   homeassistant/binary_sensor/openqiara_<ID>/config
Payload: {
  "name": "OpenQiara DWS <ID>",
  "unique_id": "openqiara_dws_<ID>",
  "device_class": "opening",
  "state_topic": "openqiara/sensor/<ID>/state",
  "value_template": "{{ value_json.open | lower if value_json.open is defined else '' }}",
  "payload_on": "true",
  "payload_off": "false",
  "device": { "identifiers": ["openqiara_<ID>"], ... }
}
```

State : `{"open": true, "battery": 100, "reachable": true, "temperature": 21}`

Après un démarrage d'openqiarad, une porte n'a pas d'état tant qu'elle n'a
rien rapporté : une porte laissée ouverte n'envoie rien de plus. Jusque-là :

- à la (re)connexion MQTT, son état n'est pas republié : celui retenu sur le
  broker reste, et Home Assistant le relit après son propre redémarrage ;
- sa pile ou sa joignabilité partent sans `open`
  (`{"battery": 100, "reachable": false}`) : le `value_template` ne rend
  rien et Home Assistant garde l'état qu'il avait.

### PIR (binary_sensor)

```
Topic:   homeassistant/binary_sensor/openqiara_<ID>/config
State:   {"motion": true, "battery": 100, "reachable": true}
```

Même règle que la porte : `motion` est absent tant que le détecteur n'a rien
rapporté depuis le démarrage.

### SRN (siren)

```
Topic:     homeassistant/siren/openqiara_<ID>/config
Command:   openqiara/siren/<ID>/set   (payload: "true"/"false" ou "ON"/"OFF")
State:     openqiara/sensor/<ID>/state  {"active": false, "state": "armed", "battery": 81, "reachable": true}
```

`active` est vrai quand la sirène hurle, quel que soit le déclencheur :
openqiara, Alarmo, ou la sirène elle-même pendant une panne de la caméra.
`state` (attribut) est l'état qu'elle rapporte : `off`, `test`,
`exit_delay`, `armed`, `entry_delay`, `alert`, `alert_over` (alarme
déclenchée qui ne hurle plus, jusqu'au désarmement). Une automatisation
HA peut s'en servir pour apprendre une intrusion vue pendant une panne.

HA envoie `true`/`ON` → son de test à pleine puissance, si la sirène n'est
pas armée. HA envoie `false`/`OFF` → désarme la sirène (openqiara la
réarme si l'alarme l'est encore).

### Alarme (alarm_control_panel)

Une commande retenue par le courtier sur `openqiara/alarm/set` est ignorée
(rejouée à chaque démarrage, elle désarmerait l'alarme ou le demanderait à
Alarmo après chaque redémarrage d'OpenQiara) ; publier les commandes sans
l'indicateur de rétention, comme Home Assistant le fait.

Publiée en mode `standalone` uniquement (en mode `alarmo`, c'est Alarmo
qui publie sa propre entité `alarm_control_panel`).

```
Topic:     homeassistant/alarm_control_panel/openqiara_alarm/config
State:     openqiara/alarm/state        ("disarmed", "armed_away", "armed_night", "pending", "triggered", "arming")
Command:   openqiara/alarm/set          ("ARM_AWAY", "ARM_NIGHT", "DISARM")
```

Device "OpenQiara Alarm" séparé du KPD physique. Les commandes reçues
sur `openqiara/alarm/set` portent `Source=Remote` côté engine.

### Mode Alarmo bridge

Quand `alarm.mode = "alarmo"` :

- openqiarad subscribe `alarmo/state` (configurable via `alarm.alarmo_state_topic`)
- openqiarad publie sur `alarmo/command` (configurable via `alarm.alarmo_command_topic`)
- Pas d'entité `alarm_control_panel` propre côté openqiarad
- La sirène suit les transitions `alarmo/state`, armée en miroir (voir
  [sensors.md](sensors.md), « La sirène tient l'alarme »)

### Entités supplémentaires

`reachable` passe à `false` quand le capteur se tait trop longtemps :
30 min pour la sirène (keepalive toutes les 10 min), 26 h pour les autres
(heartbeat toutes les ~12 h). Une porte dont la pile est morte est donc
signalée au plus tard le lendemain.

Pour chaque capteur, une entité batterie et une entité température :
```
homeassistant/sensor/openqiara_<ID>_battery/config
homeassistant/sensor/openqiara_<ID>_temperature/config
```

La batterie est en pourcentage, calculé comme fbxhome le faisait à partir
du niveau que le capteur envoie dans ses heartbeats. Les capteurs envoient
leur température d'eux-mêmes, rarement : l'entité reste « inconnue »
jusqu'au premier envoi, puis la dernière valeur est gardée même après un
redémarrage.

### Réglages d'image

hlcamd, le service vidéo du constructeur, conserve ses paramètres d'image
dans `/data/hlcamd-parameters.json` (valeur, défaut, minimum et maximum
natifs). OpenQiara lit ce fichier chaque minute et expose, sur l'appareil
« OpenQiara Caméra », une liste **fermée** de réglages (`internal/videoparams`) :

| Entité | Domaine | Sujet de commande | Clé hlcamd | Bornes (unités affichées) |
|---|---|---|---|---|
| Temps de pose maximal (nuit) | `number` | `openqiara/video/night_max_shutter_us/set` | `config.sensor.night.MaxShutterUS` | 1 000 à 14 000 µs, pas 500 |
| Gain capteur maximal (nuit) | `number` | `openqiara/video/night_max_sensor_gain/set` | `config.sensor.night.MaxSensorGain` | 1 à 8 000 x (× 1024 côté hlcamd) |
| Gain numérique maximal (nuit) | `number` | `openqiara/video/night_max_isp_gain/set` | `config.sensor.night.MaxISPGain` | 1 à 16 383 |
| Seuil de passage en mode nuit | `number` | `openqiara/video/d2n_threshold/set` | `config.sensor.d2n-threshold` | −50 000 à −20 000, pas 1 000 |
| Luminosité (jour) | `number` | `openqiara/video/day_brightness/set` | `config.sensor.day.brightness` | 0 à 100 (bornes natives), défaut d'usine 75 |
| Contraste (jour) | `number` | `openqiara/video/day_contrast/set` | `config.sensor.day.contrast` | 0 à 100, défaut 50 |
| Saturation (jour) | `number` | `openqiara/video/day_saturation/set` | `config.sensor.day.saturation` | 0 à 100, défaut 75 |
| Clarté (jour) | `number` | `openqiara/video/day_lightness/set` | `config.sensor.day.lightness` | 0 à 100, défaut 55 |
| Restaurer les réglages de nuit par défaut | `button` | `openqiara/video/cmd` (`restore-night`) | les quatre réglages de nuit | — |
| Restaurer les réglages de jour par défaut | `button` | `openqiara/video/cmd` (`restore-day`) | les quatre réglages de jour | — |
| Restaurer tous les réglages d'image par défaut | `button` | `openqiara/video/cmd` (`restore-defaults`) | tous | — |
| Réglages de nuit par défaut, Réglages de jour par défaut, Réglages d'image par défaut | `binary_sensor` × 3 | — | — | ON quand le groupe (ou tout) est au défaut d'usine |
| Paramètres d'image natifs | `sensor` | — | — | nombre de paramètres ; attributs : `val`, `def`, `min`, `max` de chaque clé `config.*` |

État : `openqiara/video/state` (retenu), par exemple
`{"night_max_shutter_us":14000,"night_max_sensor_gain":8000,"night_max_isp_gain":16383,"d2n_threshold":-50000,"day_brightness":51,"day_contrast":50,"day_saturation":50,"day_lightness":55,"defaults":false,"night_defaults":true,"day_defaults":false,"read_at":"2026-10-27T12:00:00Z"}`.
Les défauts sont ceux d'usine inscrits par hlcamd dans son fichier (`def`) : une
luminosité ou une saturation changée depuis Home Assistant met l'indicateur « Réglages
de jour par défaut » à OFF, et le bouton « Restaurer les réglages de jour par défaut »
les ramène à l'usine (75).
Paramètres natifs : `openqiara/video/native` (retenu).

Règles d'écriture :

- une valeur hors des bornes du tableau, ou hors du minimum et du maximum
  que hlcamd lui-même inscrit dans son fichier, est refusée et journalisée ;
  un maximum de nuit ne dépasse jamais le défaut du constructeur (relevé du
  d'une caméra réelle : hlcamd borne les clés `night.*` à 0 et 4294967295, les bornes
  du tableau sont donc la seule protection) ;
- l'écriture passe par `fbxbusctl set hlcamd video_settings`, comme le
  volet de vie privée pour le mode jour/nuit ; une seule écriture à la fois
  (une rafale de commandes ne lance jamais plus d'un `fbxbusctl`, les autres
  sont refusées et journalisées), une écriture par seconde au
  plus, 60 par heure au plus ; les entités `number` sont en saisie
  (`mode: box`), pas en curseur ;
- une commande retenue par le courtier (rejouée à chaque démarrage) est
  ignorée ;
- le fichier de hlcamd reste la vérité : la valeur écrite s'affiche aussitôt,
  puis le fichier est relu une seconde plus tard et chaque minute ; si
  hlcamd n'a pas conservé la valeur, l'entité revient à ce qu'il a gardé et
  le journal le dit ;
- les écritures sont verrouillées quand la configuration ne dit rien : les entités
  restent, en lecture seule de fait ; `"video": {"lock": false}` dans
  `openqiara.json` les autorise. La distribution OpenQIARA Claude V15 les déverrouille
  à l'installation (réglage `REGLAGES_IMAGE` de l'outil d'installation), et
  `reglage.sh reglages-image verrouilles|deverrouilles` les change ensuite ;
- sans `/data/hlcamd-parameters.json` (machine de développement), aucune de
  ces entités n'est publiée et celles d'une version antérieure sont retirées.

Le mode jour/nuit (`config.sensor.night_day_mode`) n'est pas exposé
 : le volet de vie privée le pilote déjà (jour forcé volet fermé,
pour que le relais du filtre infrarouge ne claque pas toute la nuit derrière
le volet ; auto volet ouvert). L'exposer aurait permis à « Restaurer les
réglages de nuit » de remettre le mode auto volet fermé, et l'indicateur
« Réglages de nuit par défaut » aurait été éteint volet fermé.

### Diagnostics ajoutés

Sur `openqiara/diag/state`, en plus des champs existants : `clock_ok`
(horloge réglée par NTP, la caméra n'a pas d'horloge matérielle et démarre
en 1970), `boot_time` (horodatage du démarrage, publié seulement quand
l'horloge est réglée), `cpu_pct` (processeur occupé depuis la lecture
précédente, `/proc/stat`), `load_1m` (`/proc/loadavg`), `wifi_link_quality`
(`/proc/net/wireless`, échelle du pilote), `hlcamd_running` (le service vidéo
tourne), `hlcamd_uptime_s` (depuis quand il tourne : une baisse est une relance
de la vidéo, ce qui précède les coupures SSH observées sur la caméra).

### Codec vidéo

Sur `openqiara/diag/state`, trois champs disent le codec de la vidéo, lu sur
le SPS du flux de `hlcamd` (voir [video.md](video.md), « Codec vidéo ») :

| Entité | Domaine | Clé | Valeurs |
|---|---|---|---|
| Codec vidéo | `sensor` (enum) | `video_codec` | `H.264`, `H.265` : le codec servi par RTSP et HLS (celui du flux dès qu'un SPS a été lu, celui du réglage avant) |
| Codec vidéo configuré | `sensor` (enum) | `video_codec_configured` | le réglage `video.codec` (`H.264` sans réglage) |
| Codec vidéo différent du réglage | `binary_sensor` (`problem`) | `video_codec_mismatch` | `ON` quand le flux contredit le réglage ; le flux est servi tel quel |

Un changement de codec déclenche une publication immédiate, sans attendre la
minute. Le document porte aussi `video_nal` (compteurs de NAL depuis le
démarrage : `vps`, `sps`, `pps`, `key`, `slice`, `sei`, `aud`, `other`),
sans entité : à lire dans les attributs ou avec un `template`.

Il n'y a **pas** de `select` de codec : la bascule exige de relancer `hlcamd`
avec une autre option, donc un redémarrage de la caméra (ou une relance de
`hlcamd` puis le bouton « Relancer OpenQiara » de Qiara Plus) après avoir
changé `video.codec` dans `openqiara.json`. Avec Qiara Plus v8, l'entité
« Codec vidéo demandé à hlcamd » (`video_codec_hlcamd`) dit l'option avec
laquelle `hlcamd` tourne (`H.264`, `H.265` ou `defaut`), relevée sur sa
ligne de commande.

## Sync bidirectionnelle

- **Capteur → HA** : openqiarad publie l'état sur le state topic à chaque event
- **HA → OpenQiara** : openqiarad subscribe aux command topics (alarme, sirène)
- **Web UI → HA** : les changements d'état alarme depuis la web UI sont publiés sur MQTT
- **HA → Web UI** : les commandes HA mettent à jour l'état dans la web UI via le callback
