# OpenQIARA Claude V15 et QIARA Plus v10

Distribution prête à l'emploi d'[OpenQiara](https://github.com/Caligone/openqiara) pour les caméras **Qiara** (modèle rond à cache, « HOMELABCAM ») reliées à **Home Assistant**. Le cloud Qiara est arrêté depuis octobre 2025 : avec cette distribution, la caméra et ses capteurs 868 MHz fonctionnent en local, par MQTT.

## Télécharger

**[paquet/OpenQIARA-Claude-V15.zip](paquet/OpenQIARA-Claude-V15.zip)**. Son empreinte SHA-256 est dans [`paquet/OpenQIARA-Claude-V15.zip.sha256`](paquet/OpenQIARA-Claude-V15.zip.sha256).

Le mode d'emploi complet est dans [LISEZ-MOI.md](LISEZ-MOI.md), également présent dans le zip. En résumé :

1. remplir `configuration.txt` (Wi-Fi, clé SSH, courtier MQTT) ;
2. lancer l'outil qui correspond à la caméra :
   - **caméra jamais modifiée** : préparer la carte microSD avec `preparer-carte-sd.sh` (Linux, macOS) ou `Preparer-carte-SD.ps1` (Windows, par WSL et usbipd-win) ;
   - **caméra déjà sous OpenQiara** : mise à niveau par SSH avec `mettre-a-niveau.sh` ou `Mettre-a-niveau.ps1` ;
3. remettre la carte dans la caméra : l'installation se termine seule, et la caméra écrit un rapport ;
4. dans Home Assistant, les entités arrivent par MQTT. Copier le paquet d'alertes et la vue de `home-assistant/`.

## Ce que la distribution apporte

- Vidéo **H.265** réglable : débit, image clé, détection de personnes de la caméra.
- **Réglages d'image** de l'ancienne application Qiara pilotables depuis Home Assistant.
- Santé de la caméra et qualité de l'air dans Home Assistant.
- Meilleure résistance aux coupures du Wi-Fi et de l'alimentation.
- **QIARA Plus** :
  - lanceur à quatre emplacements ;
  - surveillant ;
  - mise à jour avec essai et retour arrière automatique ;
  - SSH de secours en option.
- Installation **sans édition à la main** : un seul fichier de configuration. L'appairage radio d'origine et les fichiers du constructeur, dont la licence de la détection de personnes, sont repris.
- Services du cloud Qiara neutralisés à la source. Le retour est possible.

## Contenu du dépôt

| Dossier | Contenu |
|---|---|
| `paquet/` | Le paquet prêt à l'emploi : binaires ARM compilés de façon reproductible, outils et mode d'emploi. |
| `installation/` | Outils de l'ordinateur : préparation de la carte SD, mise à niveau par SSH, scripts Windows, configuration. |
| `camera/oqc/` | Installeur exécuté par la caméra, réglages vidéo, neutralisation des services du cloud. |
| `openqiara/` | Sources d'OpenQiara (Go), avec les modifications de cette distribution. |
| `qiara-plus/` | Sources, outils construits (`dist/`) et suites d'essais de QIARA Plus. |
| `home-assistant/` | Paquet d'alertes et vue de tableau de bord. |
| `essais/simulateur-windows/` | Simulateur des scripts Windows : faux `wsl.exe` et `usbipd.exe`, 28 scénarios, rejeu sous Linux. |
| `outils/` | Mesure d'un flux RTSP (H.264 et H.265). |

Pour reconstruire le paquet : `sh construire-paquet.sh`. Il faut Go 1.26, zig, UPX et zip, et les binaires obtenus sont identiques à ceux du paquet.

## État des essais

- **Caméra réelle** : réglages vidéo (H.265, débit, image clé), réglages d'image et QIARA Plus.
- **Banc d'essai neuf**, avec carte d'origine simulée et qemu-arm :
  - préparation de la carte, installation et rapport ;
  - mise à niveau par SSH d'une caméra sous OpenQiara rc22, et sa relance ;
  - changement de réglage ;
  - reprises après coupure.
- **Code** : tests Go (26 paquets) et 13 suites QIARA Plus, sans échec.
- **Windows** : les deux scripts sont éprouvés par le simulateur sous Windows PowerShell 5.1 réel (28 scénarios sur 28).
- **Reste à confirmer sur du vrai matériel** :
  - la reconnaissance du lecteur de carte par usbipd-win et WSL ;
  - macOS ;
  - une première installation complète par un autre utilisateur.

Retours bienvenus par les *issues* du dépôt.

## Limites connues

- HomeKit : H.264 seulement.
- Une seule caméra par Home Assistant, car OpenQiara donne des identifiants fixes aux entités.
- Le flux RTSP n'a pas de mot de passe. Le mot de passe administrateur de l'interface web est à choisir dès la fin de l'installation.

## Licence et origine

- Licence MIT, voir [LICENSE](LICENSE).
- OpenQiara : © Caligone et contributeurs ([dépôt d'origine](https://github.com/Caligone/openqiara)).
- OpenQIARA Claude V15 et QIARA Plus v10 : © 2026 Vins069. Écrits avec Claude (Anthropic).
- Projet indépendant, affilié ni à Qiara, ni à Cofidur, ni à Free.
