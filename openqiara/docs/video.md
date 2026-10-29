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

**Cohérence avec le flux.** Le réglage dit ce qui est *demandé* à `hlcamd` ; le flux dit ce qu'il *fait*. openqiarad lit le codec sur le SPS de chaque image clé (`internal/nal`, en-tête d'un octet en H.264, de deux en H.265, SPS vérifié par analyse) : au démarrage, une sonde lit le flux pendant 20 s au plus (volet ouvert), puis chaque diffusion le surveille. Si le flux n'est pas dans le codec configuré (par exemple `hlcamd` relancé par le script du constructeur, ou `/data/hlcamd_options` en désaccord), le flux est servi **tel qu'il est** : erreur dans le journal, entité « Codec vidéo différent du réglage » à `ON` dans Home Assistant, RTSP refait sa description et déconnecte ses lecteurs (ils se reconnectent et lisent le bon SDP), HLS relance son muxer. Aucun NAL d'un codec n'est jamais empaqueté comme l'autre ; tant que le flux n'a pas montré son SPS, RTSP n'envoie rien avant la première image clé.

**Changer de codec** (R2 : un fichier sur `/data`, annulable en retirant la valeur) :

1. écrire `"video": {"codec": "h265"}` dans `/data/openqiara.json` (et, sur une caméra où `hlcamd` est lancé par `post_boot.sh` avec `/data/hlcamd_options`, y mettre `--use-h265` à la place de `--use-h264`) ;
2. redémarrer la caméra (ou relancer `hlcamd` avec la nouvelle option puis OpenQiara : bouton « Relancer OpenQiara » de Qiara Plus) ; il n'y a **pas** d'entité de bascule : `hlcamd` doit être relancé, ce qu'un `select` MQTT ne peut pas faire proprement ;
3. vérifier l'entité « Codec vidéo » (`H.265`) et « Codec vidéo différent du réglage » (`OFF`), puis Frigate/go2rtc (voir la documentation de Frigate pour la configuration) ;
4. retour : retirer la valeur (ou `h264`), rétablir `--use-h264`, redémarrer. Les jeux de paramètres RTSP sont conservés par codec (`openqiara_rtsp_h264_params`, `openqiara_rtsp_h265_params`) : chacun retrouve son `DESCRIBE` complet dès le premier démarrage.

**Limites du H.265.**

- HomeKit (flux live, RFC 6184) et HomeKit Secure Video (fMP4 `avc1`) n'acceptent que le H.264 : avec `video.codec: h265`, l'accessoire caméra n'est pas publié (erreur journalisée) ; si le flux passe en H.265 alors que le réglage dit H.264, chaque session live est refusée et chaque enregistrement répondu « non pris en charge », sans plantage. Un pont Apple se ferait côté serveur (go2rtc, transcodage).
- HLS : fMP4 (`hvc1`) au lieu de MPEG-TS (gohlslib ne fait le MPEG-TS qu'en H.264 ; les lecteurs HLS attendent le HEVC en fMP4). Safari le lit nativement ; Chrome et Edge via hls.js avec décodage HEVC matériel ; Firefox ne décode pas le HEVC sur la plupart des plates-formes : passer par RTSP → go2rtc (WebRTC H.265, ou sortie transcodée H.264).
- WebRTC H.265 : Frigate ≥ 0.16.3, Home Assistant ≥ 2026.5.3, Chrome ≥ 136, applications HA Android/iOS. Prévoir une seconde sortie go2rtc transcodée en H.264 pour les autres clients.
- Le débit et l'intervalle d'image clé ne changent pas avec le codec : ce sont des réglages à part (ci-dessous).
- Changement de codec en cours de route (`hlcamd` relancé dans l'autre codec pendant qu'openqiarad tourne) : l'unité d'accès tamponnée à cet instant n'est ré-empaquetée que si elle porte le SPS du nouveau codec ; une unité de l'ancien codec est abandonnée et les lecteurs reconnectés reçoivent l'image clé suivante (2 s au plus) avec ses jeux de paramètres (contrôle du 28/10/2026).

**Banc sans caméra.** `go run ./cmd/feedhlcamd -codec h265 -file capture.h265 -fps 30` rejoue une capture Annex B (de la caméra ou de synthèse) sur le multicast de `hlcamd` (224.0.0.1:9600 par `lo`, format de fragments réel) pour alimenter un vrai openqiarad ; `go run ./cmd/synthrtsp` sert le flux de test directement en RTSP ; `sh scripts/build-arm.sh v15 2026-10-29` compile le binaire ARM avec une empreinte reproductible (`-buildvcs=false`). Mesure côté client : `outils/rtsp_mesure.py` (à la racine de la distribution) (H.264 et H.265). Vérifications faites sur ce banc le 28/10/2026 : capture H.264 réelle de la caméra et flux H.265 1080p (GOP fermé de 60, jeux de paramètres répétés) servis sans perte en RTSP (`ffprobe` : `h264` / `hevc` 1920×1080, image clé toutes les 2,000 s, `sprop-vps/sps/pps` annoncés dès le second DESCRIBE), HLS fMP4 `hvc1`, désaccord réglage/flux et bascule H.265 → H.264 en cours de flux. Sous qemu-user, l'adhésion au groupe multicast échoue (`setsockopt: protocol not available`) : le démon s'y essaie en natif, les tests Go s'y rejouent compilés pour ARM.

## Débit, image clé et détection interne (OpenQIARA Claude V15)

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
