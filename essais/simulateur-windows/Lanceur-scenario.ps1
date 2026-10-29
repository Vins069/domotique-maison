# Lanceur-scenario.ps1 : lance UN script Windows de la distribution (Preparer-carte-SD.ps1 ou Mettre-a-niveau.ps1) dans
# un processus PowerShell neuf, comme le ferait l'utilisateur, avec les quelques remplacements que le simulateur exige :
#   - le registre des distributions WSL (HKCU\...\Lxss) est simule (SIM_LXSS distributions « Ubuntu ») ;
#   - Read-Host repond SIM_REPONSE ; Start-Sleep est raccourci (50 ms) ;
#   - Start-Process wsl.exe lance le faux wsl.exe (le vrai serait trouve dans System32 avant le PATH).
# wsl.exe et usbipd.exe ne sont PAS remplaces ici : ce sont de vrais programmes (faux outils compiles) trouves en tete
# du PATH, appeles exactement comme les vrais (codes de sortie, sortie standard en UTF-8, erreurs sur la sortie d'erreur).
# Parametres par variables d'environnement : SIM_SCRIPT, SIM_ARGS (« BusId=2-3;Configuration=C:\...;Essai »), SIM_FAUX.
$ErrorActionPreference = 'Continue'
$journal = Join-Path $env:SIM_DOSSIER 'appels.log'
function Noter($t) { [IO.File]::AppendAllText($journal, "ps`t$t`n", (New-Object Text.UTF8Encoding($false))) }

function Get-ChildItem {
  if (@($args | Where-Object { "$_" -like '*\CurrentVersion\Lxss*' }).Count -gt 0) {
    Noter 'registre Lxss lu'
    for ($i = 0; $i -lt [int]$env:SIM_LXSS; $i++) { [pscustomobject]@{ PSPath = "SIM:distribution$i" } }
    return
  }
  Microsoft.PowerShell.Management\Get-ChildItem @args
}
function Get-ItemProperty {
  if (@($args | Where-Object { "$_" -like 'SIM:*' }).Count -gt 0) { return [pscustomobject]@{ DistributionName = 'Ubuntu' } }
  Microsoft.PowerShell.Management\Get-ItemProperty @args
}
function Read-Host { param($Prompt) Noter "Read-Host $Prompt -> $env:SIM_REPONSE"; Write-Host "$Prompt : $env:SIM_REPONSE"; return $env:SIM_REPONSE }
function Start-Sleep { param($Seconds, $Milliseconds) Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 50 }
function Start-Process {
  param($FilePath, $ArgumentList, $WindowStyle = 'Normal', [switch]$PassThru)
  if ($FilePath -eq 'wsl.exe') { $FilePath = Join-Path $env:SIM_FAUX 'wsl.exe' }
  Noter "Start-Process $FilePath $($ArgumentList -join ' ')"
  Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle $WindowStyle -PassThru:$PassThru
}
function Stop-Process {
  param($Id, [switch]$Force, $ErrorAction)
  Noter "Stop-Process $Id"
  Microsoft.PowerShell.Management\Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}

$p = @{}
foreach ($x in ($env:SIM_ARGS -split ';')) {
  if (-not $x) { continue }
  $k = $x.IndexOf('=')
  if ($k -lt 0) { $p[$x] = $true } else { $p[$x.Substring(0, $k)] = $x.Substring($k + 1) }
}
Noter "lancement $env:SIM_SCRIPT $(($p.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' ')"
$global:LASTEXITCODE = 0
try { & $env:SIM_SCRIPT @p; $c = $LASTEXITCODE }
catch { Noter "exception non rattrapee : $($_.Exception.Message)"; Write-Host "EXCEPTION : $($_.Exception.Message)"; $c = 98 }
Noter "fin code $c"
exit $c
