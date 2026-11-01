# OpenQIARA Claude V16 et QIARA Plus v10

Distribution prête à l'emploi d'[OpenQiara](https://github.com/Caligone/openqiara) pour les caméras Qiara (modèle rond à cache, « HOMELABCAM ») reliées à Home Assistant. Elle s'installe en copiant un paquet sur la carte microSD de la caméra, ou par SSH sur une caméra qui fait déjà tourner OpenQiara. La caméra termine ensuite l'installation seule, puis rédige un rapport.

Par rapport à OpenQiara v0.1.0-rc.23, elle apporte :

- **la vidéo H.265** (moitié du débit à qualité égale), avec un débit et une image clé réglables. Le codec servi est celui de la configuration : si la caméra en produit un autre, rien n'est servi et Home Assistant le signale, au lieu d'un flux mal étiqueté ;
- **les réglages d'image de l'application Qiara dans Home Assistant** : luminosité, saturation, contraste, clarté, vision de nuit, rotation, réglages de nuit ;
- **la santé de la caméra et la qualité de l'air** dans Home Assistant ;
- **une meilleure résistance** aux coupures du Wi-Fi et de l'alimentation ;
- **QIARA Plus**, une couche de fiabilité : lanceur à quatre emplacements (factory, prev, good, new), surveillant, mise à jour avec essai puis retour arrière automatique.

**Nouveau dans la V16** (par rapport à la V15) :

- base OpenQiara **v0.1.0-rc.23** : plusieurs codes pour le clavier (l'API `/api/v1/kpd/codes` remplace `/api/v1/kpd/code`), état « inconnu » d'un capteur qui n'a pas encore parlé depuis le démarrage, correctifs du projet ;
- **mises à jour de la distribution** par `mettre-a-niveau.sh`, avec l'essai et le retour arrière automatique de QIARA Plus (une mise à jour automatique signée, depuis le dépôt de la distribution, est prévue pour la V17) ;
- **codec fixé par la configuration** : plus de bascule de codec en cours de flux ni de sonde au démarrage ; un désaccord entre le réglage et hlcamd est détecté, signalé (entité « Codec vidéo différent du réglage ») et rien n'est servi tant qu'il dure ;
- **correction d'un arrêt possible d'OpenQiara** à la reconnexion MQTT quand un capteur envoyait sa température au même instant (défaut présent depuis plusieurs versions) ;
- **paquet Home Assistant** : 8 alertes, dont deux nouvelles (voir § 3).

Une caméra sous V15 passe à la V16 par `mettre-a-niveau.sh` (§ 2 b) : capteurs, réglages et QIARA Plus sont conservés.

## Ce qu'il faut

- Une caméra Qiara avec sa carte microSD, et ses capteurs 868 MHz déjà appairés.
- Un réseau Wi-Fi 2,4 GHz (mot de passe WPA2).
- Home Assistant avec un courtier MQTT (par exemple le module Mosquitto) et un compte MQTT pour la caméra.
- Une clé SSH. Pour en créer une : `ssh-keygen -t ed25519` (sous Windows, dans PowerShell, la même commande).
  - Préparation de la carte SD : seule la clé publique (`.pub`) sert, une phrase secrète ne gêne pas.
  - Mise à niveau par SSH : sous Windows, la clé ne doit pas avoir de phrase secrète (l'outil travaille sans interaction) ; sous Linux et macOS, une clé protégée fonctionne si elle est chargée dans l'agent (`ssh-add`).
- Un ordinateur :
  - **Linux** : paquet e2fsprogs, en général déjà présent ;
  - **macOS** : `brew install e2fsprogs` ;
  - **Windows 11** (ou 10 22H2) : WSL à jour avec Ubuntu (`wsl --install`, puis `wsl --update`), usbipd-win (`winget install --exact dorssel.usbipd-win`) et un **lecteur de carte USB**. Windows ne sait pas écrire les partitions Linux de la carte : le lecteur est confié à WSL le temps de l'opération. Les lecteurs intégrés à certains portables (reliés en PCIe, ou Realtek) ne passent pas dans WSL : prendre alors un lecteur USB externe.

## 1. Remplir la configuration

Ouvrir `configuration.txt` et le remplir :

- **toujours** : la clé SSH et le courtier MQTT (l'adresse seule, par exemple `192.168.1.10`) ;
- **pour la carte SD** : le Wi-Fi ;
- **pour la mise à niveau** : l'adresse de la caméra.

Les réglages par défaut sont ceux qui ont fait leurs preuves sur une caméra réelle : H.265, 2,5 Mbit/s, une image clé par seconde, services du cloud neutralisés, réglages d'image déverrouillés, QIARA Plus.

> HomeKit (Apple Maison) n'accepte que le H.264 : avec `HOMEKIT=oui`, mettre `CODEC=h264`. La mise à niveau d'une caméra où HomeKit est actif refuse le H.265.

Ce fichier contient vos mots de passe Wi-Fi et MQTT. Ne le partagez pas, et effacez-le après l'installation.

## 2 a. Caméra jamais modifiée : préparer la carte SD

1. Éteindre la caméra, retirer la carte microSD et la mettre dans l'ordinateur.
2. Lancer l'outil selon le système :
   - **Linux** : `lsblk` pour trouver la carte (3 partitions, environ 4 Go), puis `sudo bash preparer-carte-sd.sh --disque sdX` ;
   - **macOS** : `diskutil list` pour trouver la carte, puis `sudo bash preparer-carte-sd.sh --disque diskN` ;
   - **Windows** : dans PowerShell lancé en administrateur, `powershell -ExecutionPolicy Bypass -File .\Preparer-carte-SD.ps1`. Le script affiche les périphériques USB et demande le numéro (BUSID) du lecteur de carte, en général « Périphérique de stockage de masse USB ». Il confie le lecteur à WSL, prépare la carte, puis le rend à Windows. La sauvegarde est rangée dans le dossier du paquet.
3. Remettre la carte dans la caméra et la brancher. Le premier démarrage prend environ 2 minutes. L'installation se termine ensuite seule, et la caméra redémarre une fois : 10 à 15 minutes en tout.

L'outil reconnaît la carte avant toute autre action, et refuse un disque qui n'est pas celle d'une Qiara. Il fait ensuite une **sauvegarde** dans `sauvegarde-carte-<date>/` (image de /data et rcS.real, lisibles par vous seul). Il reformate seulement /data, ajoute seulement le dossier /media/oqc, et relit tout ce qu'il a écrit. Le reste de la carte n'est pas touché.

Ce qui est repris de l'ancien /data : **l'appairage radio d'origine** (les capteurs réapparaissent sans nouvel appairage), la licence de la détection de personnes (`iv_license`), les clés du constructeur (`passphrase`, `video.key`, `ssl/`), les réglages d'image de l'application Qiara et les microgiciels des capteurs.

Ajouter `--essai` pour tout contrôler sans rien écrire.

## 2 b. Caméra déjà sous OpenQiara : mise à niveau par SSH

Les capteurs, la configuration MQTT et les réglages sont conservés.

- **Linux et macOS** : `bash mettre-a-niveau.sh`
- **Windows** : `powershell -ExecutionPolicy Bypass -File .\Mettre-a-niveau.ps1` (la stratégie d'exécution de Windows bloque sinon les scripts téléchargés)

L'outil fait les contrôles, puis sauvegarde `openqiara.json`, `boot.sh` et `post_boot.sh` dans `sauvegarde-camera-<date>/`. Il dépose le paquet sur la caméra en vérifiant les empreintes. La caméra installe, redémarre une fois et rédige son rapport, que l'outil affiche à la fin. Une version plus ancienne de QIARA Plus est mise à jour, ses emplacements et ses réglages gardés.

Un codec ou un débit déjà choisi sur la caméra est gardé : la configuration ne s'applique qu'à ce qui n'a jamais été réglé. Pour changer ensuite, voir `reglage.sh` plus bas.

## 3. Home Assistant

- **Entités** : elles apparaissent seules, par MQTT, sous l'appareil « OpenQiara Caméra », avec un appareil par capteur.
- **Alertes** : copier `home-assistant/packages/openqiara_claude_v16.yaml` dans `/config/packages/` (et retirer `openqiara_claude_v15.yaml` s'il y est : les identifiants des automatisations ne portent plus de numéro de version). Il contient 8 automatisations : caméra hors ligne (et retour), aucune image servie parce que le codec diffère du réglage (et retour), détecteur de mouvement remis à zéro après un redémarrage de la caméra (sa « fin de mouvement » peut se perdre si la caméra redémarre pendant une détection), redémarrage par QIARA Plus, mise à jour en essai trop longue, carte presque pleine. Le mode d'emploi est en tête du fichier.
- **Tableau de bord** : la vue `home-assistant/tableau-de-bord-camera.yaml` regroupe l'état, les réglages d'image et la maintenance. Elle se colle dans l'éditeur YAML brut d'un tableau de bord.
- **Image en direct** : `rtsp://<adresse de la caméra>:8554/openqiara`, à lire avec Frigate, go2rtc ou l'intégration « Caméra générique ».
  - Le flux RTSP n'a pas de mot de passe : toute machine du réseau local peut le lire. Le couper dans l'interface web si vous ne vous en servez pas.
  - En H.265, la lecture dans le navigateur passe par WebRTC : Frigate 0.16.3 et plus, Home Assistant 2026.5.3 et plus, Chrome 136 et plus, applications Home Assistant.
  - Firefox ne lit pas le H.265 : prévoir une sortie transcodée en H.264 dans go2rtc.
- **Interface web de la caméra** : `http://<adresse de la caméra>`. À la première ouverture, choisir le mot de passe administrateur. Le faire dès la fin de l'installation : tant qu'il n'est pas choisi, n'importe quel appareil du réseau local peut le fixer.

## 4. Après l'installation

- **État et rapport** : `ssh root@<caméra> sh /media/oqc/installer.sh etat`. Le rapport vérifie notamment la liaison MQTT et la validation de la version complète.
- **Changer un réglage vidéo** : `ssh root@<caméra> sh /media/oqc/reglage.sh codec h264`. Les autres réglages s'écrivent de la même façon : `debit 2500000`, `image-cle 1` (ou 2), `detection non`, `reglages-image verrouilles`. La caméra redémarre pour l'appliquer.
- **Revenir en arrière** (dans cet ordre) :
  1. sur la caméra, services du cloud : `sh /media/oqc/services-cloud.sh retour` ;
  2. sur la caméra, QIARA Plus : `sh /media/oqc/qp-setup.sh uninstall --yes` ;
  3. carte complète (caméra éteinte, carte dans un ordinateur Linux ou WSL), avec la sauvegarde `sauvegarde-carte-<date>/` :
     ```
     sudo dd if=data-p2.img of=/dev/sdX2 bs=1M
     printf 'rm /etc/init.d/rcS.real\nwrite rcS.real /etc/init.d/rcS.real\nset_inode_field /etc/init.d/rcS.real mode 0100755\n' | sudo debugfs -w /dev/sdX1
     ```
     Le dossier `/media/oqc` peut ensuite être effacé.
- **Mettre à jour la distribution** : lancer `mettre-a-niveau.sh` d'une version plus récente (capteurs, réglages et QIARA Plus conservés ; essai puis validation ou retour arrière automatique). Les versions publiées par le projet OpenQiara ne contiennent pas les ajouts de la distribution : la page de mise à jour de l'interface web ne les propose pas sur une caméra sous OpenQIARA Claude.
- **Clavier avec Alarmo** : le code du clavier se dépose avec `PUT http://<caméra>/api/v1/kpd/codes` et la charge `{"codes": [{"password": "1234", "label": "Alarmo"}]}` (identifiant `admin`). L'ancien chemin `/api/v1/kpd/code` de la V15 n'existe plus : adapter la commande REST de Home Assistant si vous l'utilisiez.

## Ce qui change sur la caméra

| Partition | Modification |
|---|---|
| Système (p1) | `rcS.real` lance `/data/boot.sh` et garde le journal ext4 de /data (les mêmes correctifs que l'outil du projet OpenQiara). Si demandé, les fiches de démarrage de 9 services du cloud Qiara perdent leurs déclencheurs, avec une copie de sécurité. |
| /data (p2) | Version compacte d'OpenQIARA Claude V16 (4 Mo, secours « factory »), boot.sh, configuration, Wi-Fi, clé SSH, post_boot.sh, QIARA Plus, fichiers du constructeur repris. |
| /media (p3) | `/media/oqc` (installeur, rapport, outils, sauvegardes) et `/media/qp` (emplacements good, prev et new de QIARA Plus, dont la version complète d'OpenQIARA Claude V16 en service). |

## Ce qui sort de votre réseau

La caméra n'envoie ni image ni donnée hors de votre réseau : la vidéo et les capteurs ne vont qu'à votre courtier MQTT et à vos lecteurs vidéo. Restent des connexions sortantes sans contenu personnel :

- la mise à l'heure (service NTP du constructeur) ;
- l'interface web, quand on ouvre sa page de mise à jour, interroge GitHub (api.github.com) pour connaître la dernière version publiée ;
- le service VPN du constructeur (myriadvpn), gardé parce que son chien de garde matériel en dépend, peut encore tenter de joindre les serveurs Qiara arrêtés.

## Limites connues

- **HomeKit** et **HomeKit Secure Video** : H.264 seulement.
- **Une seule caméra par Home Assistant.** OpenQiara donne à ses entités des identifiants fixes (`openqiara_...`) : deux caméras sur le même Home Assistant se confondraient, même avec deux préfixes MQTT différents.
- **Partition /data** : elle ne fait que 20 Mio. C'est pourquoi la version complète tourne depuis /media, et que /data ne garde que la version compacte comme secours. Avec `QIARA_PLUS=non`, c'est la version compacte qui tourne en permanence : elle est décompressée en mémoire à chaque démarrage et en consomme davantage (écart non mesuré sur une caméra réelle). QIARA Plus est donc recommandé.
- **Clé d'hôte SSH** : sur certaines installations, la caméra régénère sa clé d'hôte à chaque démarrage. L'outil de mise à niveau l'accepte une fois, après le redémarrage de fin d'installation, et le signale. Au passage suivant, il indique quel fichier effacer.
- **MQTT** : l'adresse du courtier se donne en IPv4 ou par son nom (pas d'adresse IPv6). Une liaison chiffrée (TLS) se règle ensuite dans l'interface web de la caméra.
- **Éprouvé** : sur une caméra réelle (le code de la V16 y tourne, en H.265, avec QIARA Plus et le clavier), puis de bout en bout sur un banc d'essai neuf (préparation de la carte, installation, mise à niveau par SSH d'une caméra sous OpenQiara et d'une caméra sous V15, changement de réglage, sous Linux). Sous Windows, les deux scripts ont été éprouvés par un simulateur (`essais/simulateur-windows` du dépôt) : Windows PowerShell 5.1 réel, faux `wsl.exe` et `usbipd.exe`, 28 scénarios. La commande qu'ils transmettent à WSL a ensuite été rejouée sur un disque `/dev/sdd` simulé, puis la carte démarrée sur le banc. Restent à confirmer sur du vrai matériel : la reconnaissance du lecteur par usbipd-win et WSL, et macOS (vérifié par relecture seulement).

## Licence et origine

- Licence MIT (voir `LICENSE`).
- OpenQiara : © Caligone et contributeurs.
- OpenQIARA Claude V16 et QIARA Plus v10 : © 2026 Vins069. Écrits avec Claude (Anthropic).
- Ce projet n'est affilié ni à Qiara, ni à Cofidur, ni à Free.
