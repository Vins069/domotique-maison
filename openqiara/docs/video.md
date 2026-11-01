# Vidéo

## Architecture

```
hlcamd (encodeur H.264 ou H.265 hardware + micro)
   │  multicast local 224.0.0.1 : :9600 vidéo 1080p, :9700 PCM 16 kHz
   ▼
openqiarad (mediahub) ──→ HomeKit (SRTP, AAC-ELD)              H.264 seulement
                     ├─→ RTSP :8554 (H.264 ou H.265 + AAC-LC)
                     └─→ HLS /stream/ (H.264 : MPEG-TS ; H.265 : fMP4) → navigateur, VLC, Home Assistant
```

Le SoC Sigmastar encode en H.264 ou en H.265 via son encodeur hardware (`hlcamd --use-h264` ou `--use-h265`, `--no-720p --no-360p`, cf [`../scripts/camera_boot.sh`](../scripts/camera_boot.sh)) : seul le flux principal 1080p sert, couper les deux autres encodages économise environ un quart de cœur et 14 Mo. `hlcamd` envoie ses flux en multicast sur le loopback ; openqiarad les lit et sert lui-même le HLS. Le segmenteur `hls` du constructeur ne tourne plus, sauf avec la source de secours `homekit.camera.source: "hls"`.

## Codec vidéo

Le codec est un réglage de `openqiara.json`, lu au démarrage par `camera_boot.sh` (option de `hlcamd`) et par openqiarad :

```json
{
  "video": {
    "codec": "h265"
  }
}
```

| Valeur | Effet |
|---|---|
| absente, `h264` | H.264 (défaut, comme les versions précédentes) : HomeKit, HLS MPEG-TS, tous les navigateurs |
| `h265` (`H265`, `hevc` acceptés) | H.265, le mode d'origine du constructeur : moitié du débit à qualité égale, HLS en fMP4, **HomeKit refusé** |
| autre | H.264, erreur journalisée au démarrage |

**Codec fixé par la configuration.** Le codec servi par RTSP, HLS et HomeKit est celui de `video.codec`, lu une fois au démarrage d'openqiarad ; il ne change jamais pendant que le démon tourne. Tous les lancements de `hlcamd` lisent le même réglage, et changer de codec passe par une relance d'openqiarad (voir plus bas) : il n'y a pas de bascule à chaud, ni de sonde du flux au démarrage. Le `DESCRIBE` RTSP s'appuie sur le codec configuré et sur les jeux de paramètres conservés pour ce codec.

**Désaccord avec le flux : détecté et signalé.** Le réglage dit ce qui est *demandé* à `hlcamd` ; le flux dit ce qu'il *fait*. openqiarad lit le codec sur le SPS de chaque image clé (`internal/nal`, en-tête d'un octet en H.264, de deux en H.265, SPS vérifié par analyse), au fil de la diffusion. Si le flux n'est pas dans le codec configuré (par exemple `hlcamd` relancé avec une autre option, ou `/data/hlcamd_options` en désaccord) :

- erreur dans le journal, entité « Codec vidéo différent du réglage » à `ON` dans Home Assistant, publiée sans attendre la minute ;
- le flux n'est **pas servi** : le hub média jette ses unités avant tout consommateur (compteur `foreign` de `video_nal`, une ligne de journal toutes les 30 s au plus). Aucun NAL d'un codec n'est jamais empaqueté comme l'autre ; les en-têtes des jeux de paramètres, délimiteurs, images clés et tranches courantes de l'autre codec, qui précèdent son SPS quand le flux est pris en cours de GOP, sont reconnus d'eux-mêmes (`nal.Foreign`) ;
- les lecteurs RTSP restent connectés à la description du codec configuré mais ne reçoivent plus de vidéo (le son du micro continue) ; la plupart se reconnectent d'eux-mêmes après leur délai de lecture, et retrouvent la même description. HLS ne démarre pas son muxer (réponse 503 « aucune image ») et arrête celui qui tournait ; HomeKit ne reçoit rien, et HomeKit Secure Video vide son prébuffer et clôt l'enregistrement en cours ;
- quand le flux revient au codec configuré, il est de nouveau servi à partir de son SPS (image clé avec ses jeux de paramètres), et l'entité repasse à `OFF`.

Tant que le flux n'a montré aucun SPS depuis le démarrage, RTSP n'envoie rien avant la première image clé.

**Changer de codec** (R2 : un fichier sur `/data`, annulable en retirant la valeur) :

1. écrire `"video": {"codec": "h265"}` dans `/data/openqiara.json` (et, sur une caméra où `hlcamd` est lancé par `post_boot.sh` avec `/data/hlcamd_options`, y mettre `--use-h265` à la place de `--use-h264`) ;
2. redémarrer la caméra (ou relancer `hlcamd` avec la nouvelle option puis OpenQiara : bouton « Relancer OpenQiara » de Qiara Plus, qui arrête openqiarad et le relance ; il relit la configuration au démarrage). Il n'y a **pas** d'entité de bascule : `hlcamd` et openqiarad doivent être relancés, ce qu'un `select` MQTT ne peut pas faire proprement ;
3. vérifier l'entité « Codec vidéo » (`H.265`) et « Codec vidéo différent du réglage » (`OFF`), puis Frigate/go2rtc (voir la documentation de Frigate pour la configuration) ;
4. retour : retirer la valeur (ou `h264`), rétablir `--use-h264`, redémarrer. Les jeux de paramètres RTSP sont conservés par codec (`openqiara_rtsp_h264_params`, `openqiara_rtsp_h265_params`) : chacun retrouve son `DESCRIBE` complet dès le premier démarrage.

**Limites du H.265.**

- HomeKit (flux live, RFC 6184) et HomeKit Secure Video (fMP4 `avc1`) n'acceptent que le H.264 : avec `video.codec: h265`, l'accessoire caméra n'est pas publié (erreur journalisée), et toute session live ou tout enregistrement serait refusé (« non pris en charge ») ; un flux H.265 sous un réglage H.264 n'atteint pas HomeKit (le hub le jette). Un pont Apple se ferait côté serveur (go2rtc, transcodage).
- HLS : fMP4 (`hvc1`) au lieu de MPEG-TS (gohlslib ne fait le MPEG-TS qu'en H.264 ; les lecteurs HLS attendent le HEVC en fMP4). Safari le lit nativement ; Chrome et Edge via hls.js avec décodage HEVC matériel ; Firefox ne décode pas le HEVC sur la plupart des plates-formes : passer par RTSP → go2rtc (WebRTC H.265, ou sortie transcodée H.264).
- WebRTC H.265 : Frigate ≥ 0.16.3, Home Assistant ≥ 2026.5.3, Chrome ≥ 136, applications HA Android/iOS. Prévoir une seconde sortie go2rtc transcodée en H.264 pour les autres clients.
- Le débit et l'intervalle d'image clé ne changent pas avec le codec : ce sont des réglages à part (ci-dessous).
- `hlcamd` relancé dans l'autre codec pendant qu'openqiarad tourne : rien n'est servi tant que le flux contredit le réglage (désaccord signalé, voir plus haut) ; il faut relancer openqiarad après avoir mis `video.codec` en accord.

**Banc sans caméra.** `go run ./cmd/feedhlcamd -codec h265 -file capture.h265 -fps 30` rejoue une capture Annex B (de la caméra ou de synthèse) sur le multicast de `hlcamd` (224.0.0.1:9600 par `lo`, format de fragments réel) pour alimenter un vrai openqiarad ; `go run ./cmd/synthrtsp` sert le flux de test directement en RTSP ; `sh scripts/build-arm.sh v16 2026-11-01` compile le binaire ARM avec une empreinte reproductible (`-buildvcs=false`). Mesure côté client : `outils/rtsp_mesure.py` (à la racine de la distribution) (H.264 et H.265). Vérifications faites sur ce banc le 28/10/2026 : capture H.264 réelle de la caméra et flux H.265 1080p (GOP fermé de 60, jeux de paramètres répétés) servis sans perte en RTSP (`ffprobe` : `h264` / `hevc` 1920×1080, image clé toutes les 2,000 s, `sprop-vps/sps/pps` annoncés dès le second DESCRIBE), HLS fMP4 `hvc1`, désaccord réglage/flux (comportement des versions précédentes ; désormais le flux en désaccord n'est plus servi). `go run ./cmd/synthrtsp -codec h265 -configured h264` reproduit un désaccord. Sous qemu-user, l'adhésion au groupe multicast échoue (`setsockopt: protocol not available`) : le démon s'y essaie en natif, les tests Go s'y rejouent compilés pour ARM.

## Débit, image clé et détection interne (OpenQIARA Claude)

Lus par `camera_boot.sh` au démarrage, dans le même fichier que le codec, et passés à `hlcamd` :

| Clé de `video` | Option de hlcamd | Valeurs | Absente |
|---|---|---|---|
| `bitrate` | `--1080p-bitrate` | 500000 à 8000000 bits/s (2500000 éprouvé sur une liaison Wi-Fi 2,4 GHz) | débit du constructeur (1,5 Mbit/s) |
| `gop_denum` | `--gop-denum` | 1 à 30 : image clé toutes les 30/N images (1 = chaque seconde) | constructeur (2 : toutes les 0,5 s) |
| `iv_detection` | `--iv-detection` | `true` / `false` (détection de personnes de la caméra ; `false` retire ses deux entités de Home Assistant) | activée |

Une valeur hors bornes est ignorée (réglage du constructeur). Un changement demande un redémarrage de la caméra ; `scripts/test_video_codec.sh` vérifie la lecture de ces clés.

**Fichiers de réglage lus une fois par openqiarad à son démarrage** (jamais d'édition de `openqiara.json` pendant qu'il tourne : il réécrit ce fichier à partir de sa mémoire) :

- `/data/openqiara-defauts.json` : réglages par défaut d'une installation, appliqués seulement là où la configuration ne dit rien, puis le fichier est renommé `.applique` ;
- `/data/openqiara-reglages.json` : changement demandé (outil `reglage.sh` de la distribution), qui remplace la valeur en place, puis le fichier est renommé `.applique`.

Format commun : `{"video":{"codec":"h265","bitrate":2500000,"gop_denum":1,"iv_detection":true,"lock":false},"rtsp_enabled":true}` (toutes les clés sont facultatives). Un fichier illisible est renommé `.refuse` et la caméra démarre avec sa configuration telle quelle.

## Activation du flux

Le flux démarre à la demande : la première requête HLS, RTSP ou HomeKit lance le pipeline, qui s'arrête quand plus personne ne regarde. Le clapet fermé met `hlcamd` en pause : aucune image ne sort tant qu'il reste fermé.

```bash
# Ouvre le clapet et relance hlcamd
POST http://<camera>/api/v1/commands/stream/start
# Retourne: {"ok": true, "hls": "/stream/HLS_TEST.m3u8", "720": "/stream/720p/HLS_TEST.m3u8"}
```

## URLs HLS

| URL | Contenu |
|-----|---------|
| `http://<camera>/stream/HLS_TEST.m3u8` | 1080p + son |
| `http://<camera>/stream/720p/HLS_TEST.m3u8` | le même flux (URL historique de `hls`, gardée) |

## Segments

- Format : MPEG-TS (`.ts`), H.264 Constrained Baseline 1920×1080 30 i/s + AAC-LC 16 kHz mono ; en H.265, fMP4 (`_init.mp4` + segments `.mp4`, `hvc1`) avec le même son
- Durée : ~1 s par segment (une IDR toutes les 0,5 s)
- Le muxer démarre à la première requête (~1-2 s avant le premier segment) et s'arrête 30 s après la dernière
- Latence : ~3-4 s (inhérente au HLS)

## Compatibilité

| Lecteur | Support |
|---------|---------|
| Safari (Mac/iOS) | ✅ Natif |
| Chrome/Firefox | ✅ (H.264 supporté) ; en H.265 : Chrome avec décodage HEVC matériel, Firefox non |
| VLC | ✅ |
| Apple Home (HomeKit) | ✅ via SRTP (voir [`homekit.md`](homekit.md)), H.264 seulement |

## RTSP (recommandé pour NVR / détection)

Pour les consommateurs vidéo standard (Scrypted, Frigate, VLC, Home
Assistant), openqiarad expose un serveur **RTSP** natif : le 1080p de
`hlcamd` (H.264, RFC 6184, ou H.265, RFC 7798, selon le codec servi) et le
micro en **AAC-LC 16 kHz mono** (RFC 3640), encodé par openqiarad avec la
libfdk-aac de la caméra. La latence est bien plus faible qu'en HLS (~5 s) :
les NAL partent en RTP dès que `hlcamd` les émet. Sans libfdk-aac, le flux
est vidéo seule. Les jeux de paramètres (SPS/PPS, ou VPS/SPS/PPS) sont
renvoyés devant chaque image clé et annoncés dans le `DESCRIBE`
(`sprop-parameter-sets`, ou `sprop-vps`/`sprop-sps`/`sprop-pps`).

Activation dans `openqiara.json` :

```json
{
  "rtsp": {
    "enabled": true,
    "listen": ":8554",
    "path": "openqiara"
  }
}
```

URL : `rtsp://<camera>:8554/openqiara`

Le pipeline (mediahub) est partagé avec la sortie HomeKit et le HLS ; seul
le transport diffère. Le flux
démarre à la demande (première connexion RTSP) et s'arrête quand le dernier
client se déconnecte. Implémenté en Go pur via `bluenviron/gortsplib`, sans
ffmpeg.

## Shutter

Le cache objectif doit être ouvert pour voir l'image :

```
POST http://<camera>:8080/api/v1/commands/shutter
{"open": true}   # ouvrir
{"open": false}  # fermer
```

Le shutter est contrôlé via le canal charmux Shutter (port 8006).

## Limitations

- **H.265** : HomeKit et HKSV refusés, HLS en fMP4, Firefox sans décodage (voir « Codec vidéo »)
- **Latence HLS ~3-4 s** : inhérente au protocole ; RTSP et HomeKit sont bien plus réactifs
- **Son** : demande la libfdk-aac de la caméra et un binaire compilé avec CGo (release, `make daemon`)
- **Shutter + hlcamd conflit** : hlcamd occupe le port Shutter 8007. openqiarad contourne en envoyant via UDP sans bind.
