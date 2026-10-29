# Mettre-a-niveau.ps1 : depuis Windows, passe une camera Qiara qui fait deja tourner OpenQiara a OpenQIARA Claude V15
# et QIARA Plus v10, par SSH. Lance mettre-a-niveau.sh dans WSL (le meme outil que sous Linux et macOS).
# Prerequis : WSL avec une distribution (wsl --install), la cle SSH de CLE_SSH_PUBLIQUE autorisee sur la camera.
# La cle privee (meme nom sans .pub) est copiee le temps de l'operation dans WSL, avec les droits qu'exige ssh,
# puis effacee. Une cle protegee par une phrase secrete n'est pas prise en charge (mode non interactif).
# Usage : .\Mettre-a-niveau.ps1 [-Configuration .\configuration.txt] [-Camera 192.168.1.50] [-Essai]
param(
  [string]$Configuration = (Join-Path $PSScriptRoot 'configuration.txt'),
  [string]$Camera = '',
  [switch]$Essai
)
$ErrorActionPreference = 'Stop'
# sortie de wsl.exe (wslpath) en UTF-8 : sans cela, un dossier utilisateur accentue est deforme
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
function Arret($m) { Write-Host "ERREUR : $m" -ForegroundColor Red; exit 1 }
# appel de wsl.exe dont on lit la sortie ; « -e » : sans shell, un chemin avec apostrophe ou espace passe tel quel
function Wsl-Texte { ((& wsl.exe @args) -replace "`0", '') | Select-Object -First 1 }
# WSL vraiment installe : sur un Windows sans WSL, wsl.exe existe quand meme et propose l'installation en attendant une
# touche (60 s) ; on lit donc les distributions declarees (registre de l'utilisateur) sans lancer wsl.exe.
$distros = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
  ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).DistributionName } | Where-Object { $_ })
if ($distros.Count -eq 0) { Arret "WSL ou sa distribution absent : « wsl --install -d Ubuntu », redemarrer, ouvrir Ubuntu une fois pour creer le compte, puis relancer" }
if (-not (Test-Path $Configuration)) { Arret "configuration introuvable : $Configuration" }
$ici = (Wsl-Texte -e wslpath -a ($PSScriptRoot -replace '\\', '/')).Trim()
$lignes = Get-Content -LiteralPath $Configuration -Encoding UTF8
$cle = ($lignes | Where-Object { $_ -match '^\s*CLE_SSH_PUBLIQUE\s*=' } | Select-Object -Last 1) -replace '^\s*CLE_SSH_PUBLIQUE\s*=', ''
$cle = "$cle".Trim().Trim('"').Trim("'")
if (-not $cle) { Arret "CLE_SSH_PUBLIQUE vide dans $Configuration" }
if ($cle.StartsWith('~')) { $cle = Join-Path $env:USERPROFILE $cle.Substring(1).TrimStart('/', '\') }
$priv = $cle -replace '\.pub$', ''
if (-not (Test-Path -LiteralPath $cle)) { Arret "cle publique introuvable : $cle" }
if (-not (Test-Path -LiteralPath $priv)) { Arret "cle privee introuvable a cote de la cle publique : $priv" }
# copie temporaire des deux cles dans WSL (ssh refuse une cle privee lisible par tous, cas des disques Windows vus par WSL)
$dossier = '/root/.oqc-cle-' + $PID
$pubWin = (Wsl-Texte -e wslpath -a ($cle -replace '\\', '/')).Trim()
$privWin = (Wsl-Texte -e wslpath -a ($priv -replace '\\', '/')).Trim()
$tmp = Join-Path $env:TEMP ("oqc-configuration-{0}.txt" -f $PID)
$code = 1
try {
  # copie commande par commande (« -e », sans shell) : un chemin avec apostrophe casserait une ligne « sh -c » (simulateur)
  & wsl.exe -u root -e mkdir -p -m 700 $dossier
  if ($LASTEXITCODE -eq 0) { & wsl.exe -u root -e cp $privWin "$dossier/cle" }
  if ($LASTEXITCODE -eq 0) { & wsl.exe -u root -e cp $pubWin "$dossier/cle.pub" }
  if ($LASTEXITCODE -eq 0) { & wsl.exe -u root -e chmod 600 "$dossier/cle" }
  if ($LASTEXITCODE -ne 0) { throw "copie de la cle dans WSL impossible" }
  $lignes | ForEach-Object { if ($_ -match '^\s*CLE_SSH_PUBLIQUE\s*=') { "CLE_SSH_PUBLIQUE=$dossier/cle.pub" } else { $_ } } | Set-Content -LiteralPath $tmp -Encoding UTF8
  $confWsl = (Wsl-Texte -e wslpath -a ($tmp -replace '\\', '/')).Trim()
  $opts = @('--configuration', $confWsl)
  if ($Camera) { $opts += @('--camera', $Camera) }
  if ($Essai) { $opts += '--essai' }
  & wsl.exe -u root --cd $ici -e bash ./mettre-a-niveau.sh @opts
  $code = $LASTEXITCODE
}
catch { Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
finally {
  & wsl.exe -u root -e rm -rf $dossier
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
if ($code -ne 0) { Arret "la mise a niveau n'a pas abouti (voir ci-dessus)" }
