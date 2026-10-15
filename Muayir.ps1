<#
    Muayir.ps1 - Muayir, a personal Windows toolbox
    - Install tab : pick apps and install them with winget
    - Tweaks tab  : safe tweaks, every change is backed up and can be undone

    Run from file : powershell -ExecutionPolicy Bypass -File .\Muayir.ps1
    Run online    : irm "https://raw.githubusercontent.com/Muayir/Muayir/main/Muayir.ps1" | iex
#>

# Put your GitHub raw link here (used to relaunch as admin when started with irm | iex)
$ScriptUrl = 'https://raw.githubusercontent.com/Muayir/Muayir/main/Muayir.ps1'

# ---------- Admin check: relaunch elevated if needed ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Muayir needs Administrator rights. Relaunching as admin...' -ForegroundColor Yellow
    if ($PSCommandPath) {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } else {
        $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"irm '$ScriptUrl' | iex`""
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Arabic name built from char codes so the file stays plain ASCII (works in PowerShell 5.1)
$ToolNameAr = -join [char[]](0x0645,0x0639,0x0627,0x064A,0x0631)
$ToolName   = 'Muayir'

# ============================ Banner ============================
$Banner = @'
888b     d888   888     888          d8888   Y88b   d88P   8888888   8888888b.
8888b   d8888   888     888         d88888    Y88b d88P      888     888   Y88b
88888b.d88888   888     888        d88P888     Y88o88P       888     888    888
888Y88888P888   888     888       d88P 888      Y888P        888     888   d88P
888 Y888P 888   888     888      d88P  888       888         888     8888888P"
888  Y8P  888   888     888     d88P   888       888         888     888 T88b
888   "   888   Y88b. .d88P    d8888888888       888         888     888  T88b
888       888    "Y88888P"    d88P     888       888       8888888   888   T88b
'@
Clear-Host

# Neon gradient (cyan -> magenta). Falls back to plain colors on old consoles.
function Write-Neon([string]$Text, [int[]]$From = @(0,240,255), [int[]]$To = @(255,43,214)) {
    $lines = $Text -split "`r?`n"
    if (-not $Host.UI.SupportsVirtualTerminal) {
        $i = 0
        foreach ($l in $lines) { Write-Host $l -ForegroundColor $(if ($i++ % 2) { 'Magenta' } else { 'Cyan' }) }
        return
    }
    $e = [char]27
    $width = ($lines | Measure-Object -Property Length -Maximum).Maximum
    if ($width -lt 2) { $width = 2 }
    foreach ($l in $lines) {
        $sb = New-Object System.Text.StringBuilder
        for ($x = 0; $x -lt $l.Length; $x++) {
            $t = $x / ($width - 1)
            $r = [int]($From[0] + ($To[0] - $From[0]) * $t)
            $g = [int]($From[1] + ($To[1] - $From[1]) * $t)
            $b = [int]($From[2] + ($To[2] - $From[2]) * $t)
            [void]$sb.Append("$e[1;38;2;$r;$g;${b}m").Append($l[$x])
        }
        [void]$sb.Append("$e[0m")
        Write-Host $sb.ToString()
    }
}

Write-Neon $Banner
Write-Host ''
Write-Neon "========================  $ToolName  ========================" @(255,43,214) @(0,240,255)
Write-Neon "====================  Windows Toolbox  ====================" @(57,255,136) @(0,240,255)
Write-Host ''

# ============================ Core (shared with background tasks) ============================
$Core = {
    $ErrorActionPreference = 'Stop'
    $BackupDir  = Join-Path $env:LOCALAPPDATA 'Muayir'
    $BackupFile = Join-Path $BackupDir 'backup.json'
    $LogFile    = Join-Path $BackupDir 'log.txt'
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

    function Write-Log([string]$Msg, [string]$Level = 'INFO') {
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Msg
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
        $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }

    function Get-Backup {
        $h = @{}
        if (Test-Path $BackupFile) {
            $data = Get-Content $BackupFile -Raw | ConvertFrom-Json
            foreach ($p in $data.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        return $h
    }

    function Save-Backup($h) { $h | ConvertTo-Json -Depth 5 | Set-Content -Path $BackupFile -Encoding UTF8 }

    # Set a registry value, saving the original the first time it is touched
    function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
        $backup = Get-Backup
        $key = "$Path|$Name"
        if (-not $backup.ContainsKey($key)) {
            $existed = $false; $old = $null; $oldType = $Type
            if (Test-Path $Path) {
                $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
                if ($null -ne $prop) {
                    $existed = $true
                    $old     = $prop.$Name
                    $oldType = (Get-Item $Path).GetValueKind($Name).ToString()
                }
            }
            $backup[$key] = @{ Path = $Path; Name = $Name; Existed = $existed; Value = $old; Type = $oldType }
            Save-Backup $backup
        }
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }

    function New-RestorePoint {
        Write-Log 'Creating restore point...'
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\"
            Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
            Checkpoint-Computer -Description ("Muayir " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS
            Write-Log 'Restore point created.' 'OK'
            return $true
        } catch {
            Write-Log "Could not create restore point: $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }

    function Set-HighPerformance {
        $backup = Get-Backup
        if (-not $backup.ContainsKey('PowerPlan')) {
            $guid = (powercfg /getactivescheme) -split '\s+' | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } | Select-Object -First 1
            $backup['PowerPlan'] = @{ Value = $guid }
            Save-Backup $backup
        }
        powercfg /setactive SCHEME_MIN | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log 'High Performance plan not available on this PC (skipped).' 'WARN' }
    }

    function Undo-AllTweaks {
        $backup = Get-Backup
        if ($backup.Count -eq 0) { Write-Log 'Nothing to undo.' 'WARN'; return }
        foreach ($key in $backup.Keys) {
            $b = $backup[$key]
            try {
                if ($key -eq 'PowerPlan') {
                    if ($b.Value) { powercfg /setactive $b.Value | Out-Null }
                } elseif ($b.Existed) {
                    New-ItemProperty -Path $b.Path -Name $b.Name -Value $b.Value -PropertyType $b.Type -Force | Out-Null
                } else {
                    Remove-ItemProperty -Path $b.Path -Name $b.Name -ErrorAction SilentlyContinue
                }
                Write-Log "Restored $key" 'OK'
            } catch { Write-Log "Could not restore $key : $($_.Exception.Message)" 'ERROR' }
        }
        Remove-Item $BackupFile -Force
        Write-Log 'All tweaks reverted. Restart your PC.' 'OK'
    }

    # ---------- Tweak list (Rec = included in "Recommended") ----------
    $Tweaks = @(
        @{ Id = 'Temp'; Group = 'Essential'; Rec = $true; Name = 'Delete temporary files'
           Desc = 'Cleans the user and Windows temp folders.'
           Apply = { foreach ($p in @("$env:TEMP\*", "$env:SystemRoot\Temp\*")) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } } }
        @{ Id = 'Telemetry'; Group = 'Essential'; Rec = $true; Name = 'Disable telemetry'
           Desc = 'Sets diagnostic data to the minimum allowed.'
           Apply = { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 } }
        @{ Id = 'AdId'; Group = 'Essential'; Rec = $true; Name = 'Disable advertising ID'
           Desc = 'Stops apps from using your ID for personalized ads.'
           Apply = {
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
               Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 } }
        @{ Id = 'Activity'; Group = 'Essential'; Rec = $true; Name = 'Disable activity history'
           Desc = 'Stops Windows from collecting your activity timeline.'
           Apply = {
               $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
               Set-Reg $p 'EnableActivityFeed' 0; Set-Reg $p 'PublishUserActivities' 0; Set-Reg $p 'UploadUserActivities' 0 } }
        @{ Id = 'Bing'; Group = 'Essential'; Rec = $true; Name = 'Disable Bing in Start search'
           Desc = 'Start menu search only shows local results.'
           Apply = { Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 } }

        @{ Id = 'GameDVR'; Group = 'Gaming'; Rec = $true; Name = 'Disable Game DVR'
           Desc = 'Turns off background game recording that can cost FPS.'
           Apply = {
               Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
               Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 } }
        @{ Id = 'GameMode'; Group = 'Gaming'; Rec = $true; Name = 'Enable Game Mode'
           Desc = 'Lets Windows prioritize games while they run.'
           Apply = { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 } }
        @{ Id = 'Power'; Group = 'Gaming'; Rec = $false; Name = 'High Performance power plan'
           Desc = 'Max CPU performance. Uses more power, not ideal on laptops on battery.'
           Apply = { Set-HighPerformance } }
        @{ Id = 'Mouse'; Group = 'Gaming'; Rec = $false; Name = 'Disable mouse acceleration'
           Desc = 'Raw, consistent mouse movement for aiming.'
           Apply = {
               $p = 'HKCU:\Control Panel\Mouse'
               Set-Reg $p 'MouseSpeed' '0' 'String'; Set-Reg $p 'MouseThreshold1' '0' 'String'; Set-Reg $p 'MouseThreshold2' '0' 'String' } }
        @{ Id = 'Sticky'; Group = 'Gaming'; Rec = $true; Name = 'Disable Sticky Keys popup'
           Desc = 'No more popup when pressing Shift 5 times mid-game.'
           Apply = { Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String' } }

        @{ Id = 'FileExt'; Group = 'Customize'; Rec = $true; Name = 'Show file extensions'
           Desc = 'Shows .exe, .pdf and so on in File Explorer.'
           Apply = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0 } }
        @{ Id = 'Hidden'; Group = 'Customize'; Rec = $false; Name = 'Show hidden files'
           Desc = 'Shows hidden files and folders in File Explorer.'
           Apply = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1 } }
        @{ Id = 'Dark'; Group = 'Customize'; Rec = $false; Name = 'Dark mode'
           Desc = 'Dark theme for Windows and apps.'
           Apply = {
               $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
               Set-Reg $p 'AppsUseLightTheme' 0; Set-Reg $p 'SystemUsesLightTheme' 0 } }
        @{ Id = 'EndTask'; Group = 'Customize'; Rec = $false; Name = 'End task in taskbar (Win 11)'
           Desc = 'Adds End task when right-clicking apps in the taskbar.'
           Apply = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 } }
    )
}
. $Core
$ErrorActionPreference = 'Continue'

# ============================ Background task bodies ============================
$InstallBody = @'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log 'winget not found. Install "App Installer" from the Microsoft Store.' 'ERROR'; return
}
foreach ($id in $AppIds) {
    Write-Log "Installing $id ..."
    $p = Start-Process winget -ArgumentList @('install','--id',$id,'-e','--silent','--accept-source-agreements','--accept-package-agreements') -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -eq 0) { Write-Log "Installed $id" 'OK' }
    else { Write-Log "winget returned $($p.ExitCode) for $id (it may already be installed)" 'WARN' }
}
Write-Log 'Install finished.' 'OK'
'@

$UpgradeBody = @'
Write-Log 'Upgrading all apps with winget...'
Start-Process winget -ArgumentList @('upgrade','--all','--silent','--accept-source-agreements','--accept-package-agreements') -NoNewWindow -Wait | Out-Null
Write-Log 'Upgrade finished.' 'OK'
'@

$TweaksBody = @'
if ($MakeRestorePoint) { if (-not (New-RestorePoint)) { Write-Log 'Continuing without a restore point.' 'WARN' } }
foreach ($t in ($Tweaks | Where-Object { $SelectedIds -contains $_.Id })) {
    try { Write-Log "Applying: $($t.Name)"; & $t.Apply; Write-Log "Done: $($t.Name)" 'OK' }
    catch { Write-Log "Failed: $($t.Name) - $($_.Exception.Message)" 'ERROR' }
}
Write-Log 'Selected tweaks applied. Restart your PC.' 'OK'
'@

$UndoBody = 'Undo-AllTweaks'

# ============================ App list (name, winget id, icon) ============================
# icon = name from github.com/homarr-labs/dashboard-icons, or a website domain (uses its favicon)
$Apps = [ordered]@{
    'Browsers' = @(
        @('Brave','Brave.Brave','brave'), @('Chrome','Google.Chrome','google-chrome'), @('Firefox','Mozilla.Firefox','firefox'),
        @('Edge','Microsoft.Edge','microsoft-edge'), @('Opera','Opera.Opera','opera'), @('Opera GX','Opera.OperaGX','gx.me'),
        @('Vivaldi','Vivaldi.Vivaldi','vivaldi'), @('LibreWolf','LibreWolf.LibreWolf','librewolf'), @('Zen Browser','Zen-Team.Zen-Browser','zen-browser'),
        @('Tor Browser','TorProject.TorBrowser','tor') )
    'Communications' = @(
        @('Discord','Discord.Discord','discord'), @('Telegram','Telegram.TelegramDesktop','telegram'), @('WhatsApp','9NKSQGP7F2NH','whatsapp'),
        @('Zoom','Zoom.Zoom','zoom'), @('Slack','SlackTechnologies.Slack','slack'), @('Signal','OpenWhisperSystems.Signal','signal'),
        @('Teams','Microsoft.Teams','microsoft-teams'), @('Thunderbird','Mozilla.Thunderbird','thunderbird'), @('TeamSpeak','TeamSpeakSystems.TeamSpeakClient','teamspeak') )
    'Games' = @(
        @('Steam','Valve.Steam','steam'), @('Epic Games','EpicGames.EpicGamesLauncher','epic-games'), @('EA App','ElectronicArts.EADesktop','ea.com'),
        @('Ubisoft Connect','Ubisoft.Connect','ubisoft.com'), @('GOG Galaxy','GOG.Galaxy','gog.com'), @('Battle.net','Blizzard.BattleNet','battle.net'),
        @('Xbox','9MV0B5HZVK9Z','xbox'), @('Minecraft Launcher','Mojang.MinecraftLauncher','minecraft'), @('Prism Launcher','PrismLauncher.PrismLauncher','prismlauncher.org') )
    'Gaming Tools' = @(
        @('MSI Afterburner','Guru3D.Afterburner','msi.com'), @('Process Lasso','BitSum.ProcessLasso','bitsum.com'), @('HWiNFO','REALiX.HWiNFO','hwinfo.com'),
        @('CPU-Z','CPUID.CPU-Z','cpuid.com'), @('GPU-Z','TechPowerUp.GPU-Z','techpowerup.com'), @('CrystalDiskInfo','CrystalDewWorld.CrystalDiskInfo','crystalmark.info'),
        @('Parsec','Parsec.Parsec','parsec.app') )
    'Multimedia' = @(
        @('VLC','VideoLAN.VLC','videolan.org'), @('OBS Studio','OBSProject.OBSStudio','obsproject.com'), @('ShareX','ShareX.ShareX','getsharex.com'),
        @('Audacity','Audacity.Audacity','audacity'), @('HandBrake','HandBrake.HandBrake','handbrake'), @('Krita','KDE.Krita','krita.org'),
        @('Paint.NET','dotPDN.PaintDotNet','getpaint.net'), @('Blender','BlenderFoundation.Blender','blender'), @('foobar2000','PeterPawlowski.foobar2000','foobar2000.org') )
    'Utilities' = @(
        @('7-Zip','7zip.7zip','7zip'), @('WinRAR','RARLab.WinRAR','win-rar.com'), @('Notepad++','Notepad++.Notepad++','notepad-plus-plus.org'),
        @('Everything','voidtools.Everything','voidtools.com'), @('PowerToys','Microsoft.PowerToys','microsoft'), @('Windows Terminal','Microsoft.WindowsTerminal','microsoft'),
        @('Autoruns','Microsoft.Sysinternals.Autoruns','microsoft'), @('Revo Uninstaller','RevoUninstaller.RevoUninstaller','revouninstaller.com'), @('WizTree','AntibodySoftware.WizTree','diskanalyzer.com'),
        @('Rufus','Rufus.Rufus','rufus.ie'), @('qBittorrent','qBittorrent.qBittorrent','qbittorrent'), @('AnyDesk','AnyDesk.AnyDesk','anydesk'),
        @('TeamViewer','TeamViewer.TeamViewer','teamviewer.com'), @('Bitwarden','Bitwarden.Bitwarden','bitwarden'), @('Google Drive','Google.GoogleDrive','google-drive'),
        @('Malwarebytes','Malwarebytes.Malwarebytes','malwarebytes.com') )
    'Documents' = @(
        @('Adobe Reader','Adobe.Acrobat.Reader.64-bit','adobe.com'), @('SumatraPDF','SumatraPDF.SumatraPDF','sumatrapdfreader.org'), @('LibreOffice','TheDocumentFoundation.LibreOffice','libreoffice'),
        @('ONLYOFFICE','ONLYOFFICE.DesktopEditors','onlyoffice'), @('Obsidian','Obsidian.Obsidian','obsidian'), @('Notion','Notion.Notion','notion') )
    'Development' = @(
        @('VS Code','Microsoft.VisualStudioCode','visual-studio-code'), @('Git','Git.Git','git'), @('GitHub Desktop','GitHub.GitHubDesktop','github'),
        @('Python 3','Python.Python.3.13','python'), @('Node.js LTS','OpenJS.NodeJS.LTS','nodejs'), @('Docker Desktop','Docker.DockerDesktop','docker'),
        @('Postman','Postman.Postman','postman'), @('Cursor','Anysphere.Cursor','cursor.com'), @('Claude','Anthropic.Claude','claude-ai') )
    'Runtimes (for games)' = @(
        @('DirectX','Microsoft.DirectX','microsoft'), @('VC++ 2015-2022 x64','Microsoft.VCRedist.2015+.x64','microsoft'), @('VC++ 2015-2022 x86','Microsoft.VCRedist.2015+.x86','microsoft'),
        @('.NET Desktop 8','Microsoft.DotNet.DesktopRuntime.8','dotnet'), @('Java (Temurin 21)','EclipseAdoptium.Temurin.21.JRE','java') )
}

# ============================ UI (XAML) ============================
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Muayir" Width="1180" Height="740" MinWidth="820" MinHeight="520"
        Background="#0b0a12" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="NeonThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" Background="#2c2645" CornerRadius="4"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#00f0ff"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#ff2bd6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb Style="{StaticResource NeonThumb}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TopBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#eae6ff"/>
      <Setter Property="Background" Value="#181525"/>
      <Setter Property="BorderBrush" Value="#2c2645"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1.5" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#00f0ff"/>
                <Setter TargetName="bd" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#00f0ff" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SideBtn" TargetType="Button" BasedOn="{StaticResource TopBtn}">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="8,8"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>

    <Style x:Key="AppCard" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#eae6ff"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="bd" Width="215" Height="46" Margin="5" Background="#181525"
                    BorderBrush="#2c2645" BorderThickness="1.5" CornerRadius="5">
              <ContentPresenter Margin="9,0" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#ff2bd6"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#06262e"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#00f0ff"/>
                <Setter TargetName="bd" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#00f0ff" BlurRadius="16" ShadowDepth="0" Opacity="0.75"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TweakBox" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#eae6ff"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="6,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="4" BorderThickness="1.5"
                      BorderBrush="#4a3f75" Background="#12101c" VerticalAlignment="Center">
                <Path x:Name="mark" Data="M2.5,7.5 L6,11 L12.5,3.5" Stroke="#0b0a12" StrokeThickness="2.2"
                      Visibility="Collapsed" Margin="0.5,0.5,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#ff2bd6"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#00f0ff"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#00f0ff"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
                <Setter TargetName="box" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#00f0ff" BlurRadius="10" ShadowDepth="0" Opacity="0.9"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Header" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#00f0ff"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="Margin" Value="4,16,0,6"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect Color="#00f0ff" BlurRadius="10" ShadowDepth="0" Opacity="0.6"/></Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <DockPanel Margin="14">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,14">
      <TextBlock x:Name="Logo" Text="MT" DockPanel.Dock="Left" Foreground="#ff2bd6" FontWeight="Bold"
                 FontSize="28" VerticalAlignment="Center" Margin="4,0,20,4">
        <TextBlock.Effect><DropShadowEffect Color="#ff2bd6" BlurRadius="20" ShadowDepth="0" Opacity="0.9"/></TextBlock.Effect>
      </TextBlock>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
        <Button x:Name="TabInstall" Content="Install" Style="{StaticResource TopBtn}"/>
        <Button x:Name="TabTweaks"  Content="Tweaks"  Style="{StaticResource TopBtn}"/>
      </StackPanel>
      <Grid Margin="12,0,0,0">
        <TextBox x:Name="Search" Height="36" FontSize="14" Background="#12101c" Foreground="#eae6ff"
                 BorderBrush="#2c2645" BorderThickness="1.5" CaretBrush="#00f0ff" SelectionBrush="#ff2bd6"
                 Padding="8,6" VerticalContentAlignment="Center"/>
        <TextBlock x:Name="SearchHint" Text="Search apps and tweaks" Foreground="#5f5880" FontSize="14"
                   Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
      </Grid>
    </DockPanel>

    <Border DockPanel.Dock="Bottom" Margin="0,12,0,0" Padding="12,7" Background="#12101c"
            BorderBrush="#2c2645" BorderThickness="1" CornerRadius="5">
      <TextBlock x:Name="Status" Text="Ready" Foreground="#39ff88" FontFamily="Consolas" FontSize="13"/>
    </Border>

    <Grid>
      <Grid x:Name="InstallPage">
        <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#12101c" BorderBrush="#2c2645" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,14,0">
          <StackPanel>
            <TextBlock Text="Actions" Style="{StaticResource Header}" Margin="0,0,0,10"/>
            <Button x:Name="BtnInstall"   Content="Install selected" Style="{StaticResource SideBtn}" Background="#06262e" BorderBrush="#00f0ff"/>
            <Button x:Name="BtnUpgrade"   Content="Upgrade all apps" Style="{StaticResource SideBtn}"/>
            <Button x:Name="BtnClearApps" Content="Clear selection"  Style="{StaticResource SideBtn}"/>
            <TextBlock x:Name="AppCount" Text="Selected apps: 0" Foreground="#ff2bd6" FontSize="13" Margin="2,8,0,0"/>
            <TextBlock Text="Apps are installed with winget from their official sources." TextWrapping="Wrap"
                       Foreground="#5f5880" FontSize="12" Margin="2,16,0,0"/>
          </StackPanel>
        </Border>
        <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="AppsPanel"/>
        </ScrollViewer>
      </Grid>

      <Grid x:Name="TweaksPage" Visibility="Collapsed">
        <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#12101c" BorderBrush="#2c2645" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,14,0">
          <StackPanel>
            <TextBlock Text="Presets" Style="{StaticResource Header}" Margin="0,0,0,10"/>
            <Button x:Name="BtnRecommended" Content="Recommended"     Style="{StaticResource SideBtn}"/>
            <Button x:Name="BtnClearTweaks" Content="Clear selection" Style="{StaticResource SideBtn}"/>
            <TextBlock Text="Run" Style="{StaticResource Header}" Margin="0,16,0,10"/>
            <CheckBox x:Name="ChkRestore" Content="Create restore point first" IsChecked="True"
                      Style="{StaticResource TweakBox}" FontSize="13" Margin="2,0,0,12"/>
            <Button x:Name="BtnRunTweaks" Content="Run tweaks"      Style="{StaticResource SideBtn}" Background="#06262e" BorderBrush="#00f0ff"/>
            <Button x:Name="BtnUndo"      Content="Undo all tweaks" Style="{StaticResource SideBtn}" Background="#2a0a24" BorderBrush="#ff2bd6"/>
            <TextBlock Text="Every change is backed up before it is applied, so Undo puts things back exactly as they were."
                       TextWrapping="Wrap" Foreground="#5f5880" FontSize="12" Margin="2,16,0,0"/>
          </StackPanel>
        </Border>
        <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="TweaksPanel"/>
        </ScrollViewer>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}
foreach ($n in 'Logo','TabInstall','TabTweaks','Search','SearchHint','Status','InstallPage','TweaksPage','BtnInstall','BtnUpgrade',
               'BtnClearApps','AppCount','AppsPanel','TweaksPanel','BtnRecommended','BtnClearTweaks','ChkRestore','BtnRunTweaks','BtnUndo') {
    $ui[$n] = $Window.FindName($n)
}
$Brush = New-Object System.Windows.Media.BrushConverter
$Window.Title = "$ToolNameAr - $ToolName"
$ui.Logo.Text = $ToolNameAr
$ui.Logo.FontFamily = 'Segoe UI'

# Dark neon title bar (Windows 11; ignored safely on Windows 10)
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);' -ErrorAction Stop
} catch {}
$Window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        $v = 1;          [void][Win32.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)   # dark mode
        $c = 0x00120A0B; [void][Win32.Dwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$c, 4)   # caption color
        $t = 0x00FFF000; [void][Win32.Dwm]::DwmSetWindowAttribute($hwnd, 36, [ref]$t, 4)   # title text cyan
        $b = 0x00D62BFF; [void][Win32.Dwm]::DwmSetWindowAttribute($hwnd, 34, [ref]$b, 4)   # border magenta
    } catch {}
})

# ============================ App icons ============================
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
function New-AppIcon([string]$Name, [string]$Icon) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Width = 28; $grid.Height = 28
    $grid.Margin = New-Object System.Windows.Thickness(0, 0, 11, 0)

    # Letter shown until the logo downloads (or if it fails / no internet)
    $circle = New-Object System.Windows.Controls.Border
    $circle.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $circle.Background = $Brush.ConvertFromString('#221d36')
    $letter = New-Object System.Windows.Controls.TextBlock
    $letter.Text = $Name.Substring(0,1).ToUpper()
    $letter.Foreground = $Brush.ConvertFromString('#00f0ff')
    $letter.FontWeight = 'Bold'; $letter.FontSize = 13
    $letter.HorizontalAlignment = 'Center'; $letter.VerticalAlignment = 'Center'
    $circle.Child = $letter
    [void]$grid.Children.Add($circle)

    $img = New-Object System.Windows.Controls.Image
    $img.Width = 26; $img.Height = 26
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
    [void]$grid.Children.Add($img)

    if ($Icon -like '*.*') { $url = "https://www.google.com/s2/favicons?domain=$Icon&sz=64" }
    else { $url = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/$Icon.png" }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri($url)
        $bmp.DecodePixelWidth = 52
        $bmp.EndInit()
        $c = $circle
        if ($bmp.IsDownloading) { $bmp.Add_DownloadCompleted({ $c.Visibility = 'Hidden' }.GetNewClosure()) }
        else { $circle.Visibility = 'Hidden' }
        $img.Source = $bmp
    } catch {}
    return $grid
}

# ============================ Build app cards ============================
$AppBoxes = New-Object System.Collections.ArrayList
foreach ($cat in $Apps.Keys) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = "- $cat"; $h.Style = $Window.FindResource('Header')
    [void]$ui.AppsPanel.Children.Add($h)
    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($a in $Apps[$cat]) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('AppCard')
        $cb.ToolTip = "winget id: $($a[1])"
        $dp = New-Object System.Windows.Controls.DockPanel
        $ic = New-AppIcon $a[0] $a[2]
        [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
        [void]$dp.Children.Add($ic)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $a[0]; $tb.VerticalAlignment = 'Center'; $tb.TextTrimming = 'CharacterEllipsis'
        [void]$dp.Children.Add($tb)
        $cb.Content = $dp
        $cb.Add_Click({ Update-AppCount })
        [void]$wrap.Children.Add($cb)
        [void]$AppBoxes.Add([pscustomobject]@{ Box = $cb; Id = $a[1]; Name = $a[0] })
    }
    [void]$ui.AppsPanel.Children.Add($wrap)
}

# ============================ Build tweak checkboxes ============================
$TweakBoxes = [ordered]@{}
foreach ($g in ($Tweaks | ForEach-Object { $_.Group } | Select-Object -Unique)) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = "- $g"; $h.Style = $Window.FindResource('Header')
    [void]$ui.TweaksPanel.Children.Add($h)
    foreach ($t in ($Tweaks | Where-Object { $_.Group -eq $g })) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('TweakBox')
        $cb.Content = $t.Name; $cb.ToolTip = $t.Desc
        [void]$ui.TweaksPanel.Children.Add($cb)
        $TweakBoxes[$t.Id] = $cb
    }
}

# ============================ Helpers ============================
function Update-AppCount {
    $n = @($AppBoxes | Where-Object { $_.Box.IsChecked }).Count
    $ui.AppCount.Text = "Selected apps: $n"
}

function Show-Tab([string]$Name) {
    $ui.InstallPage.Visibility = if ($Name -eq 'Install') { 'Visible' } else { 'Collapsed' }
    $ui.TweaksPage.Visibility  = if ($Name -eq 'Tweaks')  { 'Visible' } else { 'Collapsed' }
    foreach ($pair in @(@($ui.TabInstall,'Install'), @($ui.TabTweaks,'Tweaks'))) {
        $on = $pair[1] -eq $Name
        $pair[0].Background  = $Brush.ConvertFromString($(if ($on) { '#06262e' } else { '#181525' }))
        $pair[0].BorderBrush = $Brush.ConvertFromString($(if ($on) { '#00f0ff' } else { '#2c2645' }))
        $pair[0].Foreground  = $Brush.ConvertFromString($(if ($on) { '#00f0ff' } else { '#eae6ff' }))
    }
}

function Set-Busy([bool]$Busy) {
    foreach ($n in 'BtnInstall','BtnUpgrade','BtnRunTweaks','BtnUndo') { $ui[$n].IsEnabled = -not $Busy }
}

# Runs work in a background runspace so the window never freezes
$script:Job = $null
$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$Timer.Add_Tick({
    if ($script:Job -and $script:Job.Handle.IsCompleted) {
        try { [void]$script:Job.PS.EndInvoke($script:Job.Handle) }
        catch { Write-Log "Task error: $($_.Exception.Message)" 'ERROR' }
        $script:Job.PS.Dispose(); $script:Job.RS.Close()
        $script:Job = $null
        $Timer.Stop()
        Set-Busy $false
        $ui.Status.Text = 'Done. See the console window for details.'
    }
})

function Start-Task([string]$Label, [string]$Body, [hashtable]$Vars = @{}) {
    if ($script:Job) { [void][System.Windows.MessageBox]::Show('A task is already running.', $ToolName); return }
    Set-Busy $true
    $ui.Status.Text = "$Label ..."
    $rs = [runspacefactory]::CreateRunspace($Host)
    $rs.Open()
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Core.ToString() + "`n" + $Body)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
    $Timer.Start()
}

# ============================ Events ============================
$ui.TabInstall.Add_Click({ Show-Tab 'Install' })
$ui.TabTweaks.Add_Click({ Show-Tab 'Tweaks' })

$ui.Search.Add_TextChanged({
    $q = $ui.Search.Text.Trim()
    $ui.SearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    foreach ($a in $AppBoxes) { $a.Box.Visibility = if (-not $q -or $a.Name -like "*$q*") { 'Visible' } else { 'Collapsed' } }
    foreach ($cb in $TweakBoxes.Values) { $cb.Visibility = if (-not $q -or $cb.Content -like "*$q*") { 'Visible' } else { 'Collapsed' } }
})

$ui.BtnClearApps.Add_Click({ foreach ($a in $AppBoxes) { $a.Box.IsChecked = $false }; Update-AppCount })

$ui.BtnInstall.Add_Click({
    $ids = @($AppBoxes | Where-Object { $_.Box.IsChecked } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { [void][System.Windows.MessageBox]::Show('Select at least one app first.', $ToolName); return }
    Start-Task "Installing $($ids.Count) app(s)" $InstallBody @{ AppIds = $ids }
})

$ui.BtnUpgrade.Add_Click({ Start-Task 'Upgrading all apps' $UpgradeBody })

$ui.BtnRecommended.Add_Click({ foreach ($t in $Tweaks) { $TweakBoxes[$t.Id].IsChecked = [bool]$t.Rec } })
$ui.BtnClearTweaks.Add_Click({ foreach ($cb in $TweakBoxes.Values) { $cb.IsChecked = $false } })

$ui.BtnRunTweaks.Add_Click({
    $ids = @($TweakBoxes.Keys | Where-Object { $TweakBoxes[$_].IsChecked })
    if ($ids.Count -eq 0) { [void][System.Windows.MessageBox]::Show('Select at least one tweak first.', $ToolName); return }
    Start-Task "Applying $($ids.Count) tweak(s)" $TweaksBody @{ SelectedIds = $ids; MakeRestorePoint = [bool]$ui.ChkRestore.IsChecked }
})

$ui.BtnUndo.Add_Click({
    $r = [System.Windows.MessageBox]::Show('Revert every tweak this tool has applied?', $ToolName, 'YesNo', 'Question')
    if ($r -eq 'Yes') { Start-Task 'Undoing tweaks' $UndoBody }
})

# ============================ Start ============================
Write-Log '[UI] Starting the interface.'
Show-Tab 'Install'
[void]$Window.ShowDialog()
