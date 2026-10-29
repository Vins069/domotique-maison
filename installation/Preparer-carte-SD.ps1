# Preparer-carte-SD.ps1 : prepare depuis Windows la carte microSD d'une camera Qiara pour OpenQIARA Claude V15.
# La carte Qiara n'a que des partitions Linux (ext4), que Windows ne sait pas ecrire : le lecteur de carte est confie
# a WSL par usbipd-win (wsl --mount n'accepte pas les lecteurs de carte ni les cles USB), puis WSL execute
# preparer-carte-sd.sh, le meme outil que sous Linux et macOS.
#
# Prerequis : Windows 11 (ou Windows 10 22H2) avec WSL 2 a jour (wsl --update ; noyau 6.6 ou plus, qui contient le
#             pilote de stockage USB) et une distribution (wsl --install -d Ubuntu) ;
#             usbipd-win (winget install --exact dorssel.usbipd-win) ;
#             un lecteur de carte USB (les lecteurs integres relies en PCIe, et certains lecteurs Realtek, ne passent
#             pas dans WSL : utiliser alors un lecteur USB externe) ;
#             PowerShell lance « en tant qu'administrateur » (usbipd bind l'exige).
# Usage :     .\Preparer-carte-SD.ps1 [-BusId 2-3] [-Configuration .\configuration.txt] [-Essai]
#             Sans -BusId, la liste des peripheriques USB est affichee et le numero (BUSID) du lecteur est demande.
param(
  [string]$BusId = '',
  [string]$Configuration = (Join-Path $PSScriptRoot 'configuration.txt'),
  [switch]$Essai
)
$ErrorActionPreference = 'Stop'
# sortie de wsl.exe (wslpath, lsblk) en UTF-8 : sans cela, un dossier utilisateur accentue est deforme
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
function Arret($m) { Write-Host "ERREUR : $m" -ForegroundColor Red; exit 1 }
# appel de wsl.exe dont on lit la sortie (fonction simple : les options passent telles quelles dans $args ;
# « -e » plutot que « -- », que PowerShell retire des arguments d'une fonction)
function Wsl-Texte { ((& wsl.exe @args) -replace "`0", '') }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Arret "lancer PowerShell en tant qu'administrateur (usbipd bind l'exige)" }
# WSL vraiment installe : sur un Windows sans WSL, wsl.exe existe quand meme et propose l'installation en attendant une
# touche (60 s) ; on lit donc les distributions declarees (registre de l'utilisateur) sans lancer wsl.exe.
$distros = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
  ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).DistributionName } | Where-Object { $_ })
if ($distros.Count -eq 0) { Arret "WSL ou sa distribution absent : « wsl --install -d Ubuntu », redemarrer, ouvrir Ubuntu une fois pour creer le compte, puis relancer" }
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { Arret "usbipd-win absent : « winget install --exact dorssel.usbipd-win », rouvrir PowerShell en administrateur, puis relancer" }
if (-not (Test-Path -LiteralPath $Configuration)) { Arret "configuration introuvable : $Configuration" }

# --- noyau WSL : le pilote de stockage USB (usb-storage) est livre en module a partir du noyau 6.6
$noyau = ((Wsl-Texte -u root -e uname -r) | Select-Object -First 1).Trim()
if ($noyau -notmatch '^(\d+)\.(\d+)') { Arret "version du noyau WSL illisible ($noyau)" }
if ([int]$Matches[1] -lt 6 -or ([int]$Matches[1] -eq 6 -and [int]$Matches[2] -lt 6)) { Arret "noyau WSL $noyau trop ancien (pas de pilote de stockage USB) : « wsl --update », puis relancer" }

# --- choix du lecteur de carte
if (-not $BusId) {
  Write-Host "Peripheriques USB (le lecteur de carte s'appelle en general « Peripherique de stockage de masse USB », « USB Mass Storage Device », « Lecteur de carte » ou porte le nom du fabricant) :"
  usbipd list | Out-Host
  $BusId = (Read-Host "BUSID du lecteur de carte (par exemple 2-3)").Trim()
}
if ($BusId -notmatch '^\d+-\d+(\.\d+)*$') { Arret "BUSID invalide : $BusId (forme attendue : 2-3)" }
$ligne = (usbipd list) | Where-Object { $_ -match "^\s*$([regex]::Escape($BusId))\s" } | Select-Object -First 1
if (-not $ligne) { Arret "aucun peripherique USB avec le BUSID $BusId (voir « usbipd list »)" }
Write-Host "Lecteur choisi : $($ligne.Trim())"
# etat = derniere colonne (« Not shared », « Shared », « Shared (forced) », « Attached ») ; attention : -match ignore la
# casse, « Shared » seul trouverait aussi « Not shared » (defaut releve par le simulateur Windows)
$etatUsb = if ($ligne -match '(Not shared|Shared(\s*\(forced\))?|Attached)\s*$') { $Matches[1] } else { '' }
if ($etatUsb -eq 'Attached') { Arret "le peripherique $BusId est deja confie a WSL : « usbipd detach --busid $BusId », puis relancer" }
$dejaPartage = ($etatUsb -like 'Shared*')

# --- configuration : chemin de la cle publique traduit pour WSL (~ = le dossier de l'utilisateur Windows)
$ici = ((Wsl-Texte -e wslpath -a ($PSScriptRoot -replace '\\', '/')) | Select-Object -First 1).Trim()
$lignes = Get-Content -LiteralPath $Configuration -Encoding UTF8
$cle = ($lignes | Where-Object { $_ -match '^\s*CLE_SSH_PUBLIQUE\s*=' } | Select-Object -Last 1) -replace '^\s*CLE_SSH_PUBLIQUE\s*=', ''
$cle = "$cle".Trim().Trim('"').Trim("'")
if (-not $cle) { Arret "CLE_SSH_PUBLIQUE vide dans $Configuration" }
if ($cle.StartsWith('~')) { $cle = Join-Path $env:USERPROFILE $cle.Substring(1).TrimStart('/', '\') }
if (-not (Test-Path -LiteralPath $cle)) { Arret "cle publique introuvable : $cle (creer une cle : ssh-keygen -t ed25519)" }
$cleWsl = ((Wsl-Texte -e wslpath -a ($cle -replace '\\', '/')) | Select-Object -First 1).Trim()
$tmp = Join-Path $env:TEMP ("oqc-configuration-{0}.txt" -f $PID)
$lignes | ForEach-Object { if ($_ -match '^\s*CLE_SSH_PUBLIQUE\s*=') { "CLE_SSH_PUBLIQUE=$cleWsl" } else { $_ } } | Set-Content -LiteralPath $tmp -Encoding UTF8
$confWsl = ((Wsl-Texte -e wslpath -a ($tmp -replace '\\', '/')) | Select-Object -First 1).Trim()

# --- outils de la distribution (e2fsprogs), avant de confier le lecteur
& wsl.exe -u root -e bash -c "command -v debugfs >/dev/null && command -v mke2fs >/dev/null || (apt-get update -qq && apt-get install -y -qq e2fsprogs)"
if ($LASTEXITCODE -ne 0) { Remove-Item $tmp -ErrorAction SilentlyContinue; Arret "installation de e2fsprogs dans WSL impossible" }

# --- lecteur confie a WSL, outil lance, lecteur rendu a Windows dans tous les cas
# WSL reste allume pendant toute l'operation (usbipd attach --wsl exige une distribution en marche)
$veille = Start-Process wsl.exe -ArgumentList '-u', 'root', '-e', 'sleep', '3600' -WindowStyle Hidden -PassThru
$code = 1; $lie = $false; $attache = $false
try {
  Start-Sleep -Seconds 2
  $avant = @(Wsl-Texte -u root -e lsblk -dnpo NAME)
  if (-not $dejaPartage) {
    usbipd bind --busid $BusId
    if ($LASTEXITCODE -ne 0) { throw "usbipd bind a echoue pour $BusId" }
    $lie = $true
  }
  usbipd attach --wsl --busid $BusId
  if ($LASTEXITCODE -ne 0) { throw "usbipd attach a echoue (lecteur utilise par un autre programme, ou pare-feu qui bloque usbipd ?)" }
  $attache = $true
  & wsl.exe -u root -e modprobe usb-storage
  $nouveau = @()
  for ($i = 0; $i -lt 20 -and $nouveau.Count -eq 0; $i++) {
    Start-Sleep -Seconds 1
    $apres = @(Wsl-Texte -u root -e lsblk -dnpo NAME)
    $nouveau = @($apres | Where-Object { $_ -and ($avant -notcontains $_) })
  }
  if ($nouveau.Count -ne 1) { throw "carte introuvable dans WSL apres le branchement du lecteur ($($nouveau.Count) disque(s) nouveau(x)) : carte bien inseree ? lecteur pris en charge ?" }
  $nom = $nouveau[0].Trim() -replace '^/dev/', ''
  Write-Host "Carte vue dans WSL : /dev/$nom"
  $opts = @('--disque', $nom, '--configuration', $confWsl)
  if ($Essai) { $opts += '--essai' }
  & wsl.exe -u root --cd $ici -e bash ./preparer-carte-sd.sh @opts
  $code = $LASTEXITCODE
}
catch { Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
finally {
  # (pas de « 2>$null » sur un programme externe : sous PowerShell 5.1 avec ErrorActionPreference=Stop, il ferait echouer le script)
  if ($attache) { & wsl.exe -u root -e sync; usbipd detach --busid $BusId | Out-Null }
  if ($lie) { usbipd unbind --busid $BusId | Out-Null }
  if ($veille -and -not $veille.HasExited) { Stop-Process -Id $veille.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
if ($code -ne 0) { Arret "la preparation de la carte a echoue (voir ci-dessus) ; le lecteur a ete rendu a Windows" }
Write-Host "Lecteur rendu a Windows : retirer la carte, puis la remettre dans la camera." -ForegroundColor Green
