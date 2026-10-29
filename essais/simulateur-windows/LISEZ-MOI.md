# Simulateur Windows de la distribution OpenQIARA Claude V15

Il essaie les deux scripts Windows du paquet, `Preparer-carte-SD.ps1` et `Mettre-a-niveau.ps1`, sur un PC Windows **sans WSL, sans usbipd-win et sans lecteur de carte**. Rien n'est installé, et le vrai `wsl.exe` n'est jamais lancé.

## Moitié Windows : `Simulateur-Windows.ps1`

Le paquet `OpenQIARA-Claude-V15.zip` est décompressé comme le ferait l'utilisateur. Les deux vrais scripts tournent ensuite sous Windows PowerShell 5.1, chacun dans un processus neuf, sur 28 scénarios :

- le cas normal et le choix interactif du lecteur ;
- un lecteur déjà partagé, déjà attaché, un partage ou un attachement refusé ;
- une carte absente, deux disques, un noyau WSL trop ancien, WSL ou usbipd-win absent ;
- une configuration ou une clé absente, une installation de e2fsprogs impossible, l'outil en échec ;
- un nom d'utilisateur avec accent, apostrophe et espace, un paquet rangé dans `Téléchargements\Dossier d'été (copie)` ;
- l'équivalent pour la mise à niveau par SSH.

Pour cela, les scripts trouvent en tête du PATH un faux `wsl.exe` et un faux `usbipd.exe`. Ce sont de vrais programmes, compilés sur place à partir de `FauxOutils.cs` par le compilateur C# de .NET Framework fourni avec Windows. Ils imitent les vrais outils :

- même découpage des arguments ;
- sortie en UTF-8, comme les programmes lancés dans WSL ;
- mêmes messages d'erreur d'usbipd (« Device is not shared… », « Option '--wsl' is required. ») ;
- état du lecteur gardé entre les appels (Not shared, Shared, Attached) ;
- découpage du shell (`sh -c`) pour repérer les apostrophes.

`Lanceur-scenario.ps1` ne remplace que ce qu'un programme externe ne peut pas imiter :

- le registre des distributions WSL ;
- `Read-Host` ;
- la durée de `Start-Sleep` ;
- le lancement du processus de veille, car `Start-Process` chercherait `wsl.exe` dans System32 avant le PATH.

Pour chaque scénario, le simulateur vérifie :

- le message affiché et le code de sortie ;
- l'ordre des appels : partage, attachement, outil, détachement, fin du partage ;
- les arguments, dont les chemins traduits pour WSL et l'option `-e` ;
- le fichier de configuration transmis (BOM, CRLF, chemin de la clé) ;
- le lecteur rendu à Windows dans son état de départ ;
- l'arrêt du processus de veille et l'effacement du fichier temporaire.

Lancement : `powershell -ExecutionPolicy Bypass -File Simulateur-Windows.ps1 [-Paquet <zip>]`. Le rapport est écrit dans `travail-<date>\rapport.txt`. Chaque scénario a son dossier : `appels-lisibles.txt`, `sortie.txt`, et dans `captures\` la commande et la configuration transmises à WSL.

## Moitié Linux : `rejouer-dans-wsl.sh`

Il rejoue sous Linux, en root, **exactement** la commande et le fichier de configuration qu'un scénario a transmis à WSL :

- les chemins `/mnt/c/...` sont recréés, avec des droits ouverts comme sous DrvFs ;
- la carte est un vrai disque `/dev/sdd` avec ses partitions `/dev/sdd1..3` ;
- l'outil reçoit « o » à sa question de confirmation.

La carte obtenue se démarre ensuite sur le banc d'essai.

`bash rejouer-dans-wsl.sh <dossier captures> <paquet.zip> <carte-origine.img> <carte-sortie.img>`

## Résultats du 29/10/2026 (PC Windows 11 sans WSL, PowerShell 5.1.26100, Windows 10.0.26300)

| Paquet | Résultat |
|---|---|
| Version précédente (`f517e24`), contre-épreuve | 14 scénarios sur 28 en échec |
| Version livrée, corrigée | 28 scénarios sur 28 réussis |

Défauts trouvés et corrigés :

1. **État du lecteur mal lu.** `-match '\bShared\b'` trouvait aussi « Not shared », car PowerShell ignore la casse. Le partage était alors sauté, et l'attachement refusé : la préparation sous Windows échouait toujours.
2. **`wsl.exe wslpath` sans `-e`.** La commande passait par le shell de la distribution, et un dossier avec apostrophe la cassait.
3. **Copie de la clé SSH par une ligne `sh -c '…'`** (mise à niveau). Elle échouait avec un nom d'utilisateur contenant une apostrophe, et laissait le dossier temporaire en cas d'échec.
4. **Sauvegarde de `rcS.real`** (relevé par le rejeu Linux). debugfs coupe sa commande aux espaces : la préparation échouait quand le paquet était rangé dans un dossier dont le chemin contient des espaces.

## Ce que le simulateur ne couvre pas

- le vrai usbipd-win et le vrai pilote USB de WSL : la détection effective du lecteur par le noyau ;
- les lecteurs qui ne passent pas dans WSL ;
- les invites de sécurité de Windows (UAC, pare-feu d'usbipd) ;
- le comportement exact de la console Windows (couleurs, saisie clavier réelle).
