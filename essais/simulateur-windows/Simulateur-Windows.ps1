# Simulateur-Windows.ps1 : simulateur des scripts Windows de la distribution OpenQIARA Claude V15
# (Preparer-carte-SD.ps1 et Mettre-a-niveau.ps1), sur un PC Windows SANS WSL, sans usbipd-win, sans lecteur de carte.
#
# Principe : le paquet livre (OpenQIARA-Claude-V15.zip) est decompresse comme le ferait l'utilisateur ; les deux vrais
# scripts sont lances par Windows PowerShell 5.1, chacun dans un processus neuf, sur une suite de scenarios. Ils trouvent
# en tete du PATH un faux wsl.exe et un faux usbipd.exe (FauxOutils.cs, compiles ici, sans installation) qui repondent
# comme les vrais et notent chaque appel. Le simulateur verifie ensuite, scenario par scenario : messages, code de
# sortie, ordre et arguments des appels, chemins traduits pour WSL, fichier de configuration transmis, lecteur USB
# toujours rendu a Windows, processus de veille arrete, fichier temporaire efface.
# Rien n'est installe ; rien n'est ecrit hors du dossier de travail ; le vrai wsl.exe n'est jamais lance.
#
# Usage : powershell -ExecutionPolicy Bypass -File Simulateur-Windows.ps1 [-Paquet <zip>] [-Travail <dossier>]
# Resultat : <Travail>\rapport.txt (et captures par scenario : appels, configuration et commande transmises a WSL).
param(
  # par defaut : le zip a cote du dossier du simulateur, sinon celui du depot (paquet\OpenQIARA-Claude-V15.zip)
  [string]$Paquet = $(foreach ($c in (Join-Path (Split-Path $PSScriptRoot -Parent) 'OpenQIARA-Claude-V15.zip'),
                                     (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'paquet\OpenQIARA-Claude-V15.zip')) {
                        if (Test-Path -LiteralPath $c) { $c; break } }),
  [string]$Travail = (Join-Path $PSScriptRoot ('travail-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$rapport = New-Object System.Collections.Generic.List[string]
function Ecrire($t) { $rapport.Add($t); Write-Output $t }   # (pas « R » : alias de Invoke-History)

Ecrire "Simulateur Windows OpenQIARA Claude V15 - $(Get-Date -Format s) - PowerShell $($PSVersionTable.PSVersion) - $([Environment]::OSVersion.VersionString)"
if (-not $Paquet -or -not (Test-Path -LiteralPath $Paquet)) { throw "paquet introuvable (indiquer -Paquet <zip>) : $Paquet" }
Ecrire "paquet : $Paquet (sha256 $((Get-FileHash -LiteralPath $Paquet -Algorithm SHA256).Hash.Substring(0, 16).ToLower()))"
New-Item -ItemType Directory -Force -Path $Travail | Out-Null

# ---------------------------------------------------------------- faux outils (compiles sur place)
$faux = Join-Path $Travail 'faux-outils'; $fauxSansUsbipd = Join-Path $Travail 'faux-outils-sans-usbipd'
New-Item -ItemType Directory -Force -Path $faux, $fauxSansUsbipd | Out-Null
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FauxOutils.cs'))) -Language CSharp `
  -OutputAssembly (Join-Path $faux 'wsl.exe') -OutputType ConsoleApplication
Copy-Item (Join-Path $faux 'wsl.exe') (Join-Path $faux 'usbipd.exe')
Copy-Item (Join-Path $faux 'wsl.exe') (Join-Path $fauxSansUsbipd 'wsl.exe')
Ecrire "faux outils compiles : $faux (wsl.exe, usbipd.exe)"

# ---------------------------------------------------------------- paquet decompresse, profils utilisateurs simules
function Deballer($dest) {
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Expand-Archive -LiteralPath $Paquet -DestinationPath $dest -Force
  return (Join-Path $dest 'OpenQIARA-Claude-V15')
}
$pkg = Deballer (Join-Path $Travail 'paquet')
$pkgAccent = Deballer (Join-Path $Travail "Téléchargements\Dossier d'été (copie)")
function Profil($dossier, [switch]$SansPrivee) {
  New-Item -ItemType Directory -Force -Path (Join-Path $dossier '.ssh') | Out-Null
  [IO.File]::WriteAllText((Join-Path $dossier '.ssh\id_ed25519.pub'), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISIMULATEURWINDOWSOPENQIARAV15xxxxxxxxxx simulateur@windows`n", $utf8)
  if (-not $SansPrivee) { [IO.File]::WriteAllText((Join-Path $dossier '.ssh\id_ed25519'), "-----BEGIN OPENSSH PRIVATE KEY-----`nfausse cle du simulateur`n-----END OPENSSH PRIVATE KEY-----`n", $utf8) }
  return $dossier
}
$profil = Profil (Join-Path $Travail 'Utilisateurs\utilisateur')
$profilAccent = Profil (Join-Path $Travail "Utilisateurs\Hélène D'Arc")
$profilSansPrivee = Profil (Join-Path $Travail 'Utilisateurs\sans-privee') -SansPrivee

# configuration : celle du paquet, remplie comme un utilisateur (Bloc-notes : UTF-8 avec BOM, fins de ligne CRLF)
$modele = [IO.File]::ReadAllLines((Join-Path $pkg 'configuration.txt'), [Text.Encoding]::UTF8)
function Conf($nom, $remplacements) {
  $l = foreach ($x in $modele) {
    $k = $x -replace '=.*$', ''
    if ($remplacements.ContainsKey($k)) { $remplacements[$k] } else { $x }
  }
  $f = Join-Path $Travail $nom
  [IO.File]::WriteAllText($f, (($l -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
  return $f
}
$base = @{ 'WIFI_SSID' = 'WIFI_SSID=Mon Réseau 2,4 GHz'; 'WIFI_MOT_DE_PASSE' = 'WIFI_MOT_DE_PASSE=motdepasse$imulé'; 'MQTT_SERVEUR' = 'MQTT_SERVEUR=192.168.1.10';
  'MQTT_UTILISATEUR' = 'MQTT_UTILISATEUR=camera'; 'MQTT_MOT_DE_PASSE' = 'MQTT_MOT_DE_PASSE=p"ass\word'; 'CAMERA_ADRESSE' = 'CAMERA_ADRESSE=192.168.1.50' }
$conf = Conf 'configuration-simulee.txt' $base
$b2 = $base.Clone(); $b2['CLE_SSH_PUBLIQUE'] = '  CLE_SSH_PUBLIQUE = "~/.ssh/id_ed25519.pub"  '
$confEspaces = Conf 'configuration-espaces.txt' $b2
$b3 = $base.Clone(); $b3['CLE_SSH_PUBLIQUE'] = 'CLE_SSH_PUBLIQUE=~/.ssh/absente.pub'
$confSansCle = Conf 'configuration-sans-cle.txt' $b3

# ---------------------------------------------------------------- scenarios
# Champs : Nom, Script (P = Preparer-carte-SD, M = Mettre-a-niveau), Args, Env (variables SIM_*), Usb (etat initial),
#          Profil, Paquet, Attendu (verifications, voir Verifier).
$P = 'Preparer-carte-SD.ps1'; $M = 'Mettre-a-niveau.ps1'
$scenarios = @(
  @{ Nom = 'P01-nominal'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Attendu = @('succes', 'sequence-carte', 'disque:sdd', 'cle-existe', 'pas-alerte') }
  @{ Nom = 'P02-choix-interactif'; Script = $P; Args = "Configuration=$conf"; Env = @{ SIM_REPONSE = '2-3' }; Attendu = @('succes', 'sequence-carte', 'liste-affichee', 'pas-alerte') }
  @{ Nom = 'P03-essai'; Script = $P; Args = "BusId=2-3;Configuration=$conf;Essai"; Attendu = @('succes', 'sequence-carte', 'arg:--essai') }
  @{ Nom = 'P04-lecteur-deja-partage'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Usb = 'Shared'; Attendu = @('succes', 'sans:usbipd bind', 'sans:usbipd unbind', 'avec:usbipd attach', 'avec:usbipd detach', 'usb-final:Shared') }
  @{ Nom = 'P05-busid-invalide'; Script = $P; Args = "BusId=abc;Configuration=$conf"; Attendu = @('echec:BUSID invalide', 'sans:usbipd bind', 'sans:Start-Process') }
  @{ Nom = 'P06-busid-inconnu'; Script = $P; Args = "BusId=9-9;Configuration=$conf"; Attendu = @('echec:aucun peripherique USB', 'sans:usbipd bind') }
  @{ Nom = 'P07-lecteur-deja-attache'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Usb = 'Attached'; Attendu = @('echec:deja confie a WSL', 'sans:usbipd detach', 'usb-final:Attached') }
  @{ Nom = 'P08-attachement-refuse'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_ATTACH = 'ko' }; Attendu = @('echec:usbipd attach a echoue', 'avec:usbipd unbind', 'sans:usbipd detach', 'veille-arretee', 'sans:OUTIL') }
  @{ Nom = 'P09-carte-absente'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_CARTE = 'aucune' }; Attendu = @('echec:carte introuvable', 'avec:usbipd detach', 'avec:usbipd unbind', 'sans:OUTIL', 'veille-arretee') }
  @{ Nom = 'P10-deux-disques'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_CARTE = 'deux' }; Attendu = @('echec:carte introuvable', 'sans:OUTIL', 'avec:usbipd unbind') }
  @{ Nom = 'P11-outil-en-echec'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_OUTIL = '1' }; Attendu = @('echec:la preparation de la carte a echoue', 'avec:usbipd detach', 'avec:usbipd unbind', 'veille-arretee') }
  @{ Nom = 'P12-noyau-ancien'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_NOYAU = '5.15.167.4-microsoft-standard-WSL2' }; Attendu = @('echec:trop ancien', 'sans:usbipd bind', 'sans:Start-Process') }
  @{ Nom = 'P13-sans-distribution'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_LXSS = '0' }; Attendu = @('echec:WSL ou sa distribution absent', 'sans:wsl ') }
  @{ Nom = 'P14-usbipd-absent'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; SansUsbipd = $true; Attendu = @('echec:usbipd-win absent', 'sans:wsl ') }
  @{ Nom = 'P15-configuration-absente'; Script = $P; Args = "BusId=2-3;Configuration=$Travail\absente.txt"; Attendu = @('echec:configuration introuvable') }
  @{ Nom = 'P16-cle-absente'; Script = $P; Args = "BusId=2-3;Configuration=$confSansCle"; Attendu = @('echec:cle publique introuvable', 'sans:usbipd bind') }
  @{ Nom = 'P17-profil-accent-apostrophe-espaces'; Script = $P; Args = "BusId=2-3;Configuration=$confEspaces"; Profil = $profilAccent; Attendu = @('succes', 'sequence-carte', 'cle-existe', 'cle-contient:Hélène D''Arc', 'pas-alerte') }
  @{ Nom = 'P18-e2fsprogs-impossible'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_E2FS = 'ko' }; Attendu = @('echec:e2fsprogs', 'sans:usbipd bind', 'temp-efface') }
  @{ Nom = 'P19-paquet-dossier-accent-apostrophe'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Paquet = $pkgAccent; Attendu = @('succes', 'sequence-carte', 'cd-ok', 'pas-alerte') }
  @{ Nom = 'P20-partage-refuse'; Script = $P; Args = "BusId=2-3;Configuration=$conf"; Env = @{ SIM_BIND = 'ko' }; Attendu = @('echec:usbipd bind a echoue', 'sans:usbipd attach', 'veille-arretee', 'usb-final:Not shared') }
  @{ Nom = 'M01-nominal'; Script = $M; Args = "Configuration=$conf;Camera=192.168.1.50"; Attendu = @('succes-m', 'outil:mettre-a-niveau.sh', 'arg:--camera 192.168.1.50', 'cle-interne', 'avec:mkdir -p -m 700 /root/.oqc-cle-', 'avec:chmod 600 /root/.oqc-cle-', 'avec:rm -rf /root/.oqc-cle-', 'pas-alerte', 'cd-ok') }
  @{ Nom = 'M02-essai'; Script = $M; Args = "Configuration=$conf;Essai"; Attendu = @('succes-m', 'arg:--essai') }
  @{ Nom = 'M03-cle-privee-absente'; Script = $M; Args = "Configuration=$conf"; Profil = $profilSansPrivee; Attendu = @('echec:cle privee introuvable', 'sans:OUTIL') }
  @{ Nom = 'M04-copie-de-cle-impossible'; Script = $M; Args = "Configuration=$conf"; Env = @{ SIM_SH = 'ko' }; Attendu = @('echec:copie de la cle', 'sans:OUTIL', 'avec:rm -rf /root/.oqc-cle-') }
  @{ Nom = 'M05-mise-a-niveau-en-echec'; Script = $M; Args = "Configuration=$conf"; Env = @{ SIM_OUTIL = '1' }; Attendu = @('echec:n''a pas abouti', 'avec:rm -rf /root/.oqc-cle-') }
  @{ Nom = 'M06-profil-accent-apostrophe'; Script = $M; Args = "Configuration=$conf"; Profil = $profilAccent; Attendu = @('succes-m', 'outil:mettre-a-niveau.sh', 'pas-alerte') }
  @{ Nom = 'M08-paquet-dossier-accent-apostrophe'; Script = $M; Args = "Configuration=$conf"; Paquet = $pkgAccent; Attendu = @('succes-m', 'cd-ok', 'pas-alerte') }
  @{ Nom = 'M07-sans-distribution'; Script = $M; Args = "Configuration=$conf"; Env = @{ SIM_LXSS = '0' }; Attendu = @('echec:WSL ou sa distribution absent', 'sans:wsl ') }
)

# ---------------------------------------------------------------- execution d'un scenario
$lanceur = Join-Path $PSScriptRoot 'Lanceur-scenario.ps1'
$cheminOrigine = $env:PATH; $profilOrigine = $env:USERPROFILE; $tempOrigine = $env:TEMP; $tmpOrigine = $env:TMP
$total = 0; $echecs = 0
foreach ($s in $scenarios) {
  $total++
  $d = Join-Path $Travail ("scenarios\" + $s.Nom); New-Item -ItemType Directory -Force -Path $d | Out-Null
  $pk = if ($s.Paquet) { $s.Paquet } else { $pkg }
  $usb0 = if ($s.Usb) { $s.Usb } else { 'Not shared' }
  [IO.File]::WriteAllLines((Join-Path $d 'etat-usb.txt'), @('1-4=Not shared', "2-3=$usb0"))
  foreach ($k in 'SIM_NOYAU', 'SIM_E2FS', 'SIM_ATTACH', 'SIM_BIND', 'SIM_CARTE', 'SIM_OUTIL', 'SIM_SH', 'SIM_REPONSE') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
  $env:SIM_LXSS = '1'
  if ($s.Env) { foreach ($k in $s.Env.Keys) { Set-Item "Env:$k" $s.Env[$k] } }
  $env:SIM_DOSSIER = $d; $env:SIM_FAUX = $faux
  $env:SIM_SCRIPT = Join-Path $pk $s.Script; $env:SIM_ARGS = $s.Args
  $env:USERPROFILE = if ($s.Profil) { $s.Profil } else { $profil }
  $env:TEMP = $d; $env:TMP = $d
  $env:PATH = $(if ($s.SansUsbipd) { $fauxSansUsbipd } else { $faux }) + ';' + $cheminOrigine
  $t0 = Get-Date
  $proc = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$lanceur`"" `
    -RedirectStandardOutput (Join-Path $d 'sortie.txt') -RedirectStandardError (Join-Path $d 'erreurs.txt') -PassThru -WindowStyle Hidden
  $null = $proc.Handle   # sans cela, ExitCode reste vide apres WaitForExit (PowerShell 5.1)
  $fini = $proc.WaitForExit(180000)
  $env:PATH = $cheminOrigine; $env:USERPROFILE = $profilOrigine; $env:TEMP = $tempOrigine; $env:TMP = $tmpOrigine
  $duree = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $pb = New-Object System.Collections.Generic.List[string]
  if (-not $fini) { $pb.Add('delai de 180 s depasse (le script attend quelque chose ?)'); try { $proc.Kill() } catch { } }
  # processus de veille (faux wsl.exe sleep) restes en vie : defaut du script
  $restes = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -like "$Travail*" })
  if ($restes.Count -gt 0) { $pb.Add("$($restes.Count) processus wsl.exe de veille encore en vie"); $restes | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
  $code = if ($fini) { $proc.ExitCode } else { -1 }
  $sortie = (Get-Content -LiteralPath (Join-Path $d 'sortie.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath (Join-Path $d 'erreurs.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
  $appels = @()
  if (Test-Path (Join-Path $d 'appels.log')) { $appels = [IO.File]::ReadAllLines((Join-Path $d 'appels.log'), [Text.Encoding]::UTF8) }
  # appels lisibles : « usbipd bind --busid 2-3 », « wsl -u root -e lsblk -dnpo NAME », « OUTIL ... », « ps Start-Process ... »
  $lis = @(foreach ($a in $appels) {
    $c = $a.Split("`t")
    if ($c[0] -eq 'wsl' -or $c[0] -eq 'usbipd') { $c[0] + ' ' + ($c[2] -replace [char]0xA6, ' ') }
    elseif ($c[0] -eq 'ps') { $c[1] }
    else { ($c -join ' ') -replace [char]0xA6, ' ' }
  })
  [IO.File]::WriteAllLines((Join-Path $d 'appels-lisibles.txt'), [string[]]@($lis), $utf8)
  $tout = ($lis -join "`n")
  # recherche sensible a la casse (« OUTIL » ne doit pas trouver le dossier « faux-outils »)
  function Pos($motif) { for ($i = 0; $i -lt $lis.Count; $i++) { if ($lis[$i] -clike "*$motif*") { return $i } }; return -1 }
  $usbFin = ((Get-Content (Join-Path $d 'etat-usb.txt')) | Where-Object { $_ -like '2-3=*' }) -replace '^2-3=', ''
  $tempRestes = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $d -Filter 'oqc-configuration-*.txt' -ErrorAction SilentlyContinue)
  if ($tempRestes.Count -gt 0) { $pb.Add('fichier temporaire de configuration non efface') }
  if ($tout -match 'ALERTE|EXCEPTION|exception non rattrapee') {
    $al = @($lis | Where-Object { $_ -match 'ALERTE|EXCEPTION|exception' }) -join ' / '
    if ($s.Attendu -contains 'pas-alerte') { $pb.Add("alerte : $al") } else { $pb.Add("(info) $al") }
  }
  foreach ($att in $s.Attendu) {
    switch -regex ($att) {
      '^succes$' { if ($sortie -notmatch 'Lecteur rendu a Windows' -or $sortie -cmatch 'ERREUR') { $pb.Add("succes attendu ; sortie : $(($sortie -replace '\s+', ' ').Trim())") } }
      '^succes-m$' { if ($sortie -cmatch 'ERREUR|EXCEPTION' -or (Pos 'OUTIL') -lt 0) { $pb.Add("succes attendu ; sortie : $(($sortie -replace '\s+', ' ').Trim())") } }
      '^echec:(.*)$' { $m = $Matches[1]; if ($sortie -notlike "*$m*") { $pb.Add("message attendu « $m » absent ; sortie : $(($sortie -replace '\s+', ' ').Trim())") }; if ($code -eq 0) { $pb.Add('code de sortie 0 malgre l''echec') } }
      '^sequence-carte$' {
        $o = @('usbipd attach --wsl --busid 2-3', 'wsl -u root -e modprobe usb-storage', 'OUTIL', 'wsl -u root -e sync', 'usbipd detach --busid 2-3')
        $pos = @($o | ForEach-Object { Pos $_ })
        if ($pos -contains -1) { $pb.Add("sequence incomplete : $(($o | Where-Object { (Pos $_) -lt 0 }) -join ' ; ')") }
        else { for ($i = 1; $i -lt $pos.Count; $i++) { if ($pos[$i] -le $pos[$i - 1]) { $pb.Add("ordre incorrect : « $($o[$i-1]) » puis « $($o[$i]) »") } } }
        if ((Pos 'usbipd bind --busid 2-3') -ge 0 -and (Pos 'usbipd bind --busid 2-3') -gt (Pos 'usbipd attach')) { $pb.Add('bind apres attach') }
        if ((Pos 'Start-Process') -lt 0) { $pb.Add('WSL non maintenu en marche (pas de processus de veille)') }
        if ((Pos 'Stop-Process') -lt 0) { $pb.Add('processus de veille jamais arrete') }
        if ($usbFin -ne $usb0) { $pb.Add("lecteur non rendu dans son etat initial : $usbFin au lieu de $usb0") }
      }
      '^disque:(.*)$' { if ((Pos "--disque $($Matches[1]) ") -lt 0) { $pb.Add("argument --disque $($Matches[1]) absent") } }
      '^arg:(.*)$' { if ((Pos $Matches[1]) -lt 0) { $pb.Add("argument « $($Matches[1]) » absent") } }
      '^outil:(.*)$' { if ((Pos "OUTIL $($Matches[1])") -lt 0) { $pb.Add("outil $($Matches[1]) jamais lance") } }
      '^avec:(.*)$' { if ((Pos $Matches[1]) -lt 0) { $pb.Add("appel attendu absent : $($Matches[1])") } }
      '^sans:(.*)$' { if ((Pos $Matches[1]) -ge 0) { $pb.Add("appel inattendu : $($lis[(Pos $Matches[1])])") } }
      '^cle-existe$' { if ((Pos 'existe=1') -lt 0 -or (Pos 'CLE') -lt 0 -or $tout -match 'CLE [^\n]*existe=0') { $pb.Add('cle publique transmise introuvable cote Windows') } }
      '^cle-interne$' { if ($tout -notmatch 'CLE /root/\.oqc-cle-\d+/cle\.pub') { $pb.Add('la configuration transmise ne pointe pas sur la copie de la cle dans WSL') } }
      '^cle-contient:(.*)$' { if ($tout -notlike "*CLE*$($Matches[1])*") { $pb.Add("chemin de cle sans « $($Matches[1]) » (encodage ?)") } }
      '^cd-ok$' { if ($tout -notmatch 'cd_ok=1') { $pb.Add('dossier du paquet mal traduit pour WSL (--cd)') } }
      '^veille-arretee$' { if ((Pos 'Start-Process') -ge 0 -and (Pos 'Stop-Process') -lt 0) { $pb.Add('processus de veille jamais arrete') } }
      '^temp-efface$' { }
      '^usb-final:(.*)$' { if ($usbFin -ne $Matches[1]) { $pb.Add("etat final du lecteur : $usbFin (attendu $($Matches[1]))") } }
      '^liste-affichee$' { if (@($lis | Where-Object { $_ -eq 'usbipd list' }).Count -lt 2) { $pb.Add('liste des peripheriques non affichee') } }
      '^pas-alerte$' { }
    }
  }
  $reels = @($pb | Where-Object { $_ -notlike '(info)*' })
  if ($reels.Count -eq 0) { Ecrire ("OK     {0,-40} {1,5} s  code {2}" -f $s.Nom, $duree, $code) }
  else { $echecs++; Ecrire ("ECHEC  {0,-40} {1,5} s  code {2}" -f $s.Nom, $duree, $code); foreach ($x in $reels) { Ecrire "         - $x" } }
  foreach ($x in @($pb | Where-Object { $_ -like '(info)*' })) { Ecrire "         $x" }
}
Ecrire ""
Ecrire "=== $total scenarios, $echecs echec(s) ==="
Ecrire "dossier de travail : $Travail"
[IO.File]::WriteAllLines((Join-Path $Travail 'rapport.txt'), $rapport, (New-Object Text.UTF8Encoding($true)))
