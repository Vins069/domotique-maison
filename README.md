# OpenQIARA Claude V15 et QIARA Plus v10

Distribution prête à l'emploi d'[OpenQiara](https://github.com/Caligone/openqiara) pour les caméras **Qiara**, le modèle rond à cache (« HOMELABCAM »). Elle remet la caméra et ses capteurs 868 MHz en service **en local, dans Home Assistant**, sans le cloud Qiara, arrêté depuis octobre 2025.

> Ce dépôt contient exactement la même distribution que [Vins069/qiara-openqiara](https://github.com/Vins069/qiara-openqiara), le dépôt principal.

**Télécharger** : [paquet/OpenQIARA-Claude-V15.zip](paquet/OpenQIARA-Claude-V15.zip). Son empreinte SHA-256 est dans [paquet/OpenQIARA-Claude-V15.zip.sha256](paquet/OpenQIARA-Claude-V15.zip.sha256).

## Qu'est-ce que c'est ?

Le kit Qiara comprend une caméra, des détecteurs d'ouverture et de mouvement, une sirène et un clavier. La caméra sert aussi de centrale radio pour les capteurs. Quand le cloud s'est arrêté, l'application et l'alarme ont cessé de fonctionner.

[OpenQiara](https://github.com/Caligone/openqiara), écrit par Caligone, remplace la partie cloud par un petit programme qui tourne directement sur la caméra. Il pilote la radio des capteurs, fait tourner l'alarme et publie tout dans Home Assistant par MQTT.

**OpenQIARA Claude V15** reprend OpenQiara v0.1.0-rc.22 et y ajoute la vidéo H.265, les réglages d'image, la santé de la caméra et une installation sans édition à la main. **QIARA Plus v10** est une couche de fiabilité installée à côté : elle relance ce qui se bloque et permet de revenir en arrière après une mise à jour ratée.

```
 Capteurs 868 MHz ──radio──► Caméra Qiara ──MQTT──► Home Assistant (+ Alarmo)
 (ouverture, mouvement,      OpenQIARA Claude V15
  sirène, clavier)           QIARA Plus v10       ──RTSP──► Frigate, go2rtc, lecteur vidéo
```

Rien ne sort de votre réseau : ni image, ni donnée de capteur.

## Ce que la distribution apporte

- **Vidéo H.265** : la moitié du débit à qualité égale. Débit et intervalle d'image clé sont réglables ; H.264 reste possible.
- **Réglages d'image** de l'ancienne application Qiara, pilotables depuis Home Assistant : luminosité, contraste, saturation, clarté, vision de nuit (automatique, forcée, coupée), rotation, réglages de nuit.
- **Santé de la caméra** dans Home Assistant : Wi-Fi, mémoire, carte SD, température, processeur, version, codec.
- **Qualité de l'air** mesurée par la caméra : composés organiques volatils, CO₂ équivalent, indice de 1 à 5.
- **Meilleure tenue aux coupures** :
  - l'état de l'alarme survit à une coupure de courant ;
  - le flux vidéo reprend proprement après une perte ;
  - une commande ancienne n'est pas rejouée au démarrage.
- **QIARA Plus** :
  - lanceur à quatre emplacements (usine, précédent, bon, nouveau) ;
  - surveillant ;
  - mise à jour avec période d'essai et retour arrière automatique ;
  - boîte noire avant redémarrage ;
  - SSH de secours en option.
- **Installation guidée** : un seul fichier de configuration, puis un outil pour Linux, macOS ou Windows. L'appairage des capteurs est conservé, comme les fichiers du constructeur, dont la licence de la détection de personnes.
- **Services du cloud Qiara neutralisés** à la source, avec retour possible.

## Avant de commencer

| Il faut | Détail |
|---|---|
| La caméra Qiara | Avec sa carte microSD d'origine, et ses capteurs déjà appairés |
| Un Wi-Fi 2,4 GHz | Mot de passe WPA2 ; la caméra ne connaît pas le 5 GHz |
| Home Assistant | Avec un courtier MQTT (par exemple le module Mosquitto) et un compte pour la caméra |
| Une clé SSH | Créée en une commande, voir l'étape 3 |
| Linux | Le paquet `e2fsprogs`, en général déjà installé |
| macOS | `brew install e2fsprogs` |
| Windows 11 (ou 10 22H2) | WSL avec Ubuntu, usbipd-win et un **lecteur de carte USB** (voir l'étape 5a) |

## Tutoriel

Comptez 30 minutes, dont 10 à 15 où la caméra travaille seule.

### Étape 1 : télécharger et vérifier le paquet

1. Téléchargez [OpenQIARA-Claude-V15.zip](paquet/OpenQIARA-Claude-V15.zip) et [son fichier .sha256](paquet/OpenQIARA-Claude-V15.zip.sha256) dans le même dossier.
2. Vérifiez que le fichier n'a pas été abîmé. La commande doit répondre « OK », ou afficher la même empreinte que le fichier `.sha256` :
   - Linux : `sha256sum -c OpenQIARA-Claude-V15.zip.sha256`
   - macOS : `shasum -a 256 -c OpenQIARA-Claude-V15.zip.sha256`
   - Windows (PowerShell) : `Get-FileHash .\OpenQIARA-Claude-V15.zip -Algorithm SHA256`
3. Décompressez le zip. Vous obtenez un dossier `OpenQIARA-Claude-V15` : toutes les commandes suivantes se lancent depuis ce dossier.

### Étape 2 : préparer Home Assistant

1. Installez un courtier MQTT s'il n'y en a pas : Paramètres, Modules complémentaires, **Mosquitto broker**, Installer, puis Démarrer.
2. Créez un compte pour la caméra. Avec Mosquitto, un utilisateur Home Assistant dédié suffit, par exemple `camera-qiara`, avec son propre mot de passe.
3. Vérifiez que l'intégration **MQTT** est configurée (Paramètres, Appareils et services).
4. Notez l'adresse IP de Home Assistant, par exemple `192.168.1.10`.

### Étape 3 : créer une clé SSH

La clé permet à l'outil, puis à vous, de se connecter à la caméra sans mot de passe.

```
ssh-keygen -t ed25519
```

La même commande marche sous Linux, macOS et Windows (PowerShell). Acceptez l'emplacement proposé. Elle crée deux fichiers ; seul `id_ed25519.pub` (la clé publique) est copié sur la caméra.

> Mise à niveau depuis Windows : laissez la phrase secrète vide, car l'outil travaille sans interaction. Sous Linux et macOS, une clé protégée fonctionne si elle est chargée par `ssh-add`.

### Étape 4 : remplir `configuration.txt`

Ouvrez `configuration.txt` avec un éditeur de texte. Une ligne par réglage, sous la forme `NOM=valeur`, sans guillemets.

| Réglage | À remplir | Exemple |
|---|---|---|
| `WIFI_SSID`, `WIFI_MOT_DE_PASSE` | Pour la carte SD | `MaBox`, `motdepasse` |
| `CLE_SSH_PUBLIQUE` | Toujours | `~/.ssh/id_ed25519.pub` (valeur proposée) |
| `MQTT_SERVEUR` | Toujours, l'adresse seule | `192.168.1.10` |
| `MQTT_UTILISATEUR`, `MQTT_MOT_DE_PASSE` | Toujours | le compte de l'étape 2 |
| `CAMERA_ADRESSE` | Pour la mise à niveau par SSH | `192.168.1.50` |

Les autres réglages ont des valeurs par défaut éprouvées sur une caméra réelle :

| Réglage | Défaut | Signification |
|---|---|---|
| `CODEC` | `h265` | `h264` si vous utilisez HomeKit |
| `DEBIT` | `2500000` | 2,5 Mbit/s en 1080p (de 500 000 à 8 000 000) |
| `IMAGE_CLE` | `1` | une image clé par seconde ; `2` pour une toutes les 0,5 s |
| `DETECTION_INTERNE` | `oui` | `non` si Frigate fait la détection |
| `REGLAGES_IMAGE` | `deverrouilles` | modifiables depuis Home Assistant, ou `verrouilles` |
| `QIARA_PLUS` | `oui` | recommandé |
| `SERVICES_CLOUD` | `neutraliser` | ou `laisser` |
| `SSH_SECOURS_PORT` | `0` | second accès SSH de secours, par exemple `2222` |
| `HOMEKIT` | `non` | `oui` exige `CODEC=h264` |

Ce fichier contient vos mots de passe : ne le partagez pas, et effacez-le après l'installation.

### Étape 5a : caméra jamais modifiée, préparer la carte SD

1. Éteignez la caméra, retirez la carte microSD et mettez-la dans l'ordinateur.
2. Lancez l'outil de votre système :
   - **Linux** : repérez la carte avec `lsblk`. Elle a trois partitions et fait environ 4 Go. Lancez ensuite `sudo bash preparer-carte-sd.sh --disque sdX`, en remplaçant `sdX` par son nom.
   - **macOS** : repérez la carte avec `diskutil list`, puis `sudo bash preparer-carte-sd.sh --disque diskN`.
   - **Windows** : Windows ne sait pas écrire les partitions Linux de la carte. Le lecteur est donc confié à WSL le temps de l'opération. Une seule fois :
     1. installez WSL : `wsl --install -d Ubuntu`, redémarrez, ouvrez Ubuntu pour créer le compte, puis `wsl --update` ;
     2. installez usbipd-win : `winget install --exact dorssel.usbipd-win`.

     Ensuite, ouvrez PowerShell **en tant qu'administrateur** dans le dossier du paquet, puis :

     ```
     powershell -ExecutionPolicy Bypass -File .\Preparer-carte-SD.ps1
     ```

     L'outil affiche les périphériques USB et demande le numéro (BUSID) du lecteur de carte, en général « Périphérique de stockage de masse USB ». Les lecteurs intégrés à certains portables (PCIe ou Realtek) ne passent pas dans WSL : prenez alors un lecteur USB externe.
3. L'outil commence par reconnaître la carte et refuse tout disque qui n'est pas celui d'une Qiara. Il demande ensuite confirmation, puis :
   - il sauvegarde `/data` dans `sauvegarde-carte-<date>/` ;
   - il reformate `/data` en reprenant l'appairage des capteurs et les fichiers du constructeur ;
   - il ajoute le dossier `/media/oqc` ;
   - il relit tout ce qu'il a écrit.

   Le reste de la carte n'est pas touché. Pour un essai à blanc, ajoutez `--essai` (`-Essai` sous Windows) : tout est contrôlé, rien n'est écrit.
4. Remettez la carte dans la caméra et branchez-la. Le premier démarrage prend environ 2 minutes. L'installation se termine ensuite seule, avec un redémarrage : **10 à 15 minutes en tout**. Ne débranchez pas la caméra pendant ce temps ; une coupure est reprise, mais elle rallonge l'installation.

### Étape 5b : caméra déjà sous OpenQiara, mise à niveau par SSH

Remplissez `CAMERA_ADRESSE`, puis lancez :

- **Linux et macOS** : `bash mettre-a-niveau.sh`
- **Windows** : `powershell -ExecutionPolicy Bypass -File .\Mettre-a-niveau.ps1` (WSL est nécessaire, usbipd-win non)

L'outil se déroule ainsi :

1. il contrôle la caméra sans rien modifier ;
2. il sauvegarde `openqiara.json`, `boot.sh` et `post_boot.sh` dans `sauvegarde-camera-<date>/` ;
3. il envoie le paquet en vérifiant les empreintes ;
4. il suit l'installation et affiche le rapport à la fin.

Les capteurs, la configuration MQTT et vos réglages sont gardés. Un codec ou un débit déjà choisi sur la caméra n'est pas remplacé. HomeKit actif et H.265 sont incompatibles : l'outil refuse alors et explique pourquoi.

### Étape 6 : vérifier l'installation

```
ssh root@<adresse de la caméra> sh /media/oqc/installer.sh etat
```

Le rapport indique si l'installation a réussi, si la liaison MQTT est établie et si la version complète est validée. L'adresse de la caméra se trouve dans la liste des appareils de votre box.

### Étape 7 : Home Assistant

1. **Entités** : elles apparaissent seules, par MQTT. On trouve l'appareil « OpenQiara Caméra » et un appareil par capteur, sous Paramètres, Appareils et services, MQTT.
2. **Alarme** : le clavier, la sirène et les détecteurs se pilotent comme avant, seuls ou avec Alarmo.
3. **Alertes** :
   1. dans `configuration.yaml`, ajoutez une fois :

      ```yaml
      homeassistant:
        packages: !include_dir_named packages
      ```

   2. copiez `home-assistant/packages/openqiara_claude_v15.yaml` dans `/config/packages/` ;
   3. vérifiez la configuration (Outils de développement, YAML) et redémarrez.

   Le paquet ajoute 5 alertes : caméra hors ligne, codec différent du réglage, redémarrage par QIARA Plus, mise à jour en essai trop longue, carte presque pleine.
4. **Tableau de bord** : `home-assistant/tableau-de-bord-camera.yaml` est une vue prête, avec l'état, les réglages d'image et la maintenance. Collez-la dans l'éditeur YAML brut d'un tableau de bord.
5. **Image en direct** : `rtsp://<adresse de la caméra>:8554/openqiara`, à lire avec Frigate, go2rtc ou l'intégration « Caméra générique ».
   - En H.265, le navigateur lit par WebRTC : Frigate 0.16.3 et plus, Home Assistant 2026.5.3 et plus, Chrome 136 et plus, ou les applications Home Assistant.
   - Firefox ne lit pas le H.265 : prévoyez une sortie H.264 dans go2rtc.
6. **Interface web de la caméra** : ouvrez `http://<adresse de la caméra>` **dès la fin de l'installation** et choisissez le mot de passe administrateur. Tant qu'il n'est pas choisi, n'importe quel appareil du réseau local peut le fixer.

### Étape 8 : changer un réglage plus tard

Tous les réglages s'écrivent de la même façon :

```
ssh root@<adresse de la caméra> sh /media/oqc/reglage.sh codec h264
```

Autres exemples : `debit 3000000`, `image-cle 2`, `detection non`, `reglages-image verrouilles`. La caméra redémarre pour appliquer le réglage. Les réglages d'image (luminosité, vision de nuit…) se changent directement dans Home Assistant.

## En cas de problème

| Symptôme | Que faire |
|---|---|
| L'outil refuse la carte | Ce n'est pas le bon disque, ou la carte n'est pas celle d'une Qiara : vérifiez avec `lsblk` ou `diskutil list` |
| Windows : le lecteur n'apparaît pas dans WSL | Lancez `wsl --update`, prenez un lecteur de carte USB externe, relancez PowerShell en administrateur |
| Windows : « lancer PowerShell en tant qu'administrateur » | Clic droit sur PowerShell, Exécuter en tant qu'administrateur |
| La caméra n'apparaît pas dans Home Assistant | Attendez 15 minutes, puis lancez la commande de l'étape 6. Vérifiez l'adresse et le compte MQTT. |
| L'image ne s'affiche pas dans le navigateur | H.265 : utilisez Chrome ou l'application Home Assistant, ou passez en H.264 (étape 8) |
| HomeKit ne voit pas la caméra | HomeKit n'accepte que le H.264 : `reglage.sh codec h264` |
| La mise à niveau signale une clé d'hôte changée | La caméra a régénéré sa clé : l'outil indique quel fichier effacer |

## Revenir en arrière

Dans cet ordre, sur la caméra :

1. services du cloud : `sh /media/oqc/services-cloud.sh retour` ;
2. QIARA Plus : `sh /media/oqc/qp-setup.sh uninstall --yes`.

Pour restaurer la carte complète, avec la sauvegarde `sauvegarde-carte-<date>/`, suivez la procédure de [LISEZ-MOI.md](LISEZ-MOI.md#4-après-linstallation). La mise à jour par l'interface web de la caméra est bloquée : une version publiée d'OpenQiara remplacerait cette distribution.

## Contenu du dépôt

| Dossier | Contenu |
|---|---|
| `paquet/` | Le paquet prêt à l'emploi : binaires ARM compilés de façon reproductible, outils et mode d'emploi |
| `installation/` | Outils de l'ordinateur : préparation de la carte SD, mise à niveau par SSH, scripts Windows, configuration |
| `camera/oqc/` | Installeur exécuté par la caméra, réglages vidéo, neutralisation des services du cloud |
| `openqiara/` | Sources d'OpenQiara (Go), avec les modifications de cette distribution |
| `qiara-plus/` | Sources, outils construits (`dist/`) et suites d'essais de QIARA Plus |
| `home-assistant/` | Paquet d'alertes et vue de tableau de bord |
| `essais/simulateur-windows/` | Simulateur des scripts Windows : faux `wsl.exe` et `usbipd.exe`, 28 scénarios, rejeu sous Linux |
| `outils/` | Mesure d'un flux RTSP (H.264 et H.265) |

Le mode d'emploi complet, également présent dans le zip, est [LISEZ-MOI.md](LISEZ-MOI.md). Pour reconstruire le paquet : `sh construire-paquet.sh`. Il faut Go 1.26, zig, UPX et zip, et les binaires obtenus sont identiques à ceux du paquet.

## État des essais

- **Caméra réelle** : vidéo H.265 (débit, image clé), réglages d'image et QIARA Plus.
- **Banc d'essai neuf**, avec une carte d'origine simulée et qemu-arm :
  - préparation de la carte, installation et rapport ;
  - mise à niveau par SSH d'une caméra sous OpenQiara rc22, et sa relance ;
  - changement de réglage ;
  - reprises après coupure.
- **Code** : tests Go (26 paquets, avec détection des accès concurrents) et 13 suites QIARA Plus, sans échec.
- **Windows** : les deux scripts sont éprouvés par le simulateur sous Windows PowerShell 5.1 réel (28 scénarios sur 28).
- **Reste à confirmer sur du vrai matériel** : la reconnaissance du lecteur de carte par usbipd-win et WSL, macOS, et une première installation complète par un autre utilisateur.

Retours bienvenus par les [issues](../../issues) du dépôt.

## Limites connues

- **HomeKit** : H.264 seulement.
- **Une seule caméra par Home Assistant** : OpenQiara donne des identifiants fixes à ses entités.
- **Flux RTSP** : il n'a pas de mot de passe ; toute machine du réseau local peut le lire. Coupez-le dans l'interface web si vous ne vous en servez pas.
- **Adresse du courtier MQTT** : IPv4 ou nom, pas d'IPv6. Le TLS se règle ensuite dans l'interface web de la caméra.

## Licence et origine

- Licence MIT, voir [LICENSE](LICENSE).
- OpenQiara : © Caligone et contributeurs ([dépôt d'origine](https://github.com/Caligone/openqiara)). Merci à lui : sans son travail, rien de ceci n'existerait. Les améliorations lui sont proposées dans le [ticket #64](https://github.com/Caligone/openqiara/issues/64).
- OpenQIARA Claude V15 et QIARA Plus v10 : © 2026 Vins069. Écrits avec Claude (Anthropic).
- Projet indépendant, affilié ni à Qiara, ni à Cofidur, ni à Free.
