<#
.SYNOPSIS
    Installs the zed-remote-open listener on Windows (the local computer, where Zed runs).

.DESCRIPTION
    - Makes sure that pythonw.exe (Python 3.10 or later) is installed.
    - Finds the listeners that are already installed or running and compares
      their versions with the new version. It updates an older version, keeps
      the same version, and stops for a newer version (use -Force to replace it).
    - Asks for the port, the SSH hosts and the token.
    - Installs zed-listener.pyw and listener.json in %LOCALAPPDATA%\zed-remote-open.
    - Creates a shortcut in the Windows Startup folder and starts the listener.
    - Adds the RemoteForward to ~/.ssh/config in a block between
      "# BEGIN zed-remote-open" and "# END zed-remote-open" markers. It asks
      before the change, keeps a backup copy, and verifies the result with "ssh -G".
    - Shows the command that installs zed on the server, with the same options.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1 -Port 7682 -Hosts myserver,myserver.ts -Yes

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [int]$Port,
    [string[]]$Hosts,
    [string]$Token,
    [switch]$NoToken,
    [string]$PythonW,
    [switch]$Force,
    [switch]$SkipSshConfig,
    [switch]$NoAutostart,
    [switch]$Yes,
    [switch]$Uninstall,
    [string]$BaseUrl = 'https://github.com/franciscocabral/zed-remote-open/raw/main'
)

$ErrorActionPreference = 'Stop'
# The installer installs only the listener of the same version (set by scripts/set-version.sh).
$InstallerVersion = '1.1.0'
$MinPython = [version]'3.10'
$DefaultPort = 7682
$InstallDir = Join-Path $env:LOCALAPPDATA 'zed-remote-open'
$Listener = Join-Path $InstallDir 'zed-listener.pyw'
$ConfigFile = Join-Path $InstallDir 'listener.json'
$LogFile = Join-Path $InstallDir 'listener.log'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'zed-listener.lnk'
$SshConfig = Join-Path $HOME '.ssh\config'
$HostPattern = '^[A-Za-z0-9._-]+$'
$TokenPattern = '^[A-Za-z0-9_-]{16,256}$'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$BlockPattern = '(?ms)^# BEGIN zed-remote-open[^\r\n]*\r?\n.*?^# END zed-remote-open[^\r\n]*(\r?\n)?'
$Interactive = [Environment]::UserInteractive -and -not $Yes

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
function Stop-WithError([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# Returns $true for yes. With -Yes, the answer is yes.
function Confirm-Action([string]$Question, [bool]$Default) {
    if ($Yes) { return $true }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $hint"
    if (-not $answer) { return $Default }
    return ($answer -match '^[yY]')
}

function Read-Value([string]$Question, [string]$Default) {
    if (-not $Interactive) { return $Default }
    $answer = Read-Host "$Question [$Default]"
    if ($answer) { return $answer }
    return $Default
}

# Returns the Python version of a pythonw.exe, or $null if it does not run.
function Get-PythonVersion([string]$Exe) {
    $out = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $out `
            -ArgumentList '-c', '"import sys; print(\"%d.%d.%d\" % sys.version_info[:3])"'
        if ($p.ExitCode -ne 0) { return $null }
        return [version]((Get-Content $out -Raw).Trim())
    } catch {
        return $null
    } finally {
        Remove-Item $out -ErrorAction SilentlyContinue
    }
}

# Returns the version of a listener file: "X.Y.Z", "unknown" (a listener with
# no version number) or $null (the file does not exist or is not a listener).
function Get-ListenerVersion([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match '(?m)^__version__\s*=\s*"([0-9]+(\.[0-9]+)*)"') { return $Matches[1] }
    if ($text -match 'Opens Zed remote projects') { return 'unknown' }
    return $null
}

# A listener path in a command line: "C:\with spaces\zed-listener.pyw" or C:\no-spaces\zed-listener.pyw
$PyPattern = '"([A-Za-z]:\\[^"]*zed-listener[^"]*\.pyw?)"|([A-Za-z]:\\[^"\s]*zed-listener[^"\s]*\.pyw?)'
function Get-ListenerPath([string]$Text) {
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, $PyPattern) | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
}

function Get-ListenerProcess {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
        Where-Object { $_.CommandLine -like '*zed-listener*' })
}

function Stop-Listener {
    $running = Get-ListenerProcess
    if ($running.Count -eq 0) { return }
    Write-Step 'A zed listener runs now. The installer must stop it.'
    $running | ForEach-Object { Write-Note "PID $($_.ProcessId): $($_.CommandLine)" }
    if (-not (Confirm-Action 'Stop it?' $true)) { Stop-WithError 'Installation stopped.' }
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Test-PortFree([int]$Number) {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Number
    try { $l.Start(); return $true } catch { return $false } finally { $l.Stop() }
}

# Sends a ping request. Returns the response line, for example "OK 1.1.0".
function Send-Ping([int]$Number, [string]$SshHost, [string]$TokenValue) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Number)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $lines = @('zro 2')
        if ($TokenValue) { $lines += "token $TokenValue" }
        $lines += @("host $SshHost", 'mode ping', 'end')
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        return (New-Object IO.StreamReader($stream)).ReadLine()
    } catch {
        return "ERR $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
}

function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# --- SSH configuration ---

# Splits a forward address from "ssh -G": "[host]:port" or "port".
function Split-Forward([string]$Text) {
    if ($Text -match '^\[(.*)\]:(\d+)$') { return @{ Host = $Matches[1]; Port = [int]$Matches[2] } }
    if ($Text -match '^(\d+)$') { return @{ Host = $null; Port = [int]$Matches[1] } }
    return $null  # Unix socket path
}

# Returns "ok" (the forward for the port is there), "conflict" (the server
# port is forwarded to a different place), "missing" or "unknown".
# -ConfigFile replaces ~/.ssh/config for the check.
function Get-ForwardState([string]$SshHost, [int]$Number, [string]$ConfigFile) {
    $ErrorActionPreference = 'Continue'  # ssh writes to stderr; do not stop
    $sshArgs = @('-G')
    if ($ConfigFile) { $sshArgs += @('-F', $ConfigFile) }
    $sshArgs += $SshHost
    $out = & $script:SshExe @sshArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    $state = 'missing'
    foreach ($line in $out) {
        if ("$line" -notmatch '^remoteforward\s+(\S+)\s+(\S+)') { continue }
        $listenText = $Matches[1]
        $connectText = $Matches[2]
        $listen = Split-Forward $listenText
        $connect = Split-Forward $connectText
        if (-not $listen -or -not $connect -or $listen.Port -ne $Number) { continue }
        if ($connect.Port -eq $Number -and $connect.Host -in @('127.0.0.1', 'localhost')) { return 'ok' }
        $state = 'conflict'
    }
    return $state
}

# Reads ~/.ssh/config. Removes a UTF-8 BOM: OpenSSH does not accept it.
function Read-SshConfig {
    $result = @{ Text = ''; HadBom = $false; Newline = "`r`n" }
    if (Test-Path -LiteralPath $SshConfig) {
        $bytes = [IO.File]::ReadAllBytes($SshConfig)
        $result.HadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $start = if ($result.HadBom) { 3 } else { 0 }
        $result.Text = $Utf8NoBom.GetString($bytes, $start, $bytes.Length - $start)
        if ($result.Text -notmatch "`r`n" -and $result.Text -match "`n") { $result.Newline = "`n" }
    }
    return $result
}

# Writes ~/.ssh/config after a backup. WriteAllText changes the file in place,
# so its permissions stay.
function Write-SshConfig([string]$Text) {
    if (Test-Path -LiteralPath $SshConfig) {
        $backup = "$SshConfig.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item -LiteralPath $SshConfig $backup
        Write-Note "Backup: $backup"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $SshConfig) | Out-Null
    }
    [IO.File]::WriteAllText($SshConfig, $Text, $Utf8NoBom)
    Write-Note "Changed $SshConfig"
}

# Adds or replaces the block. Returns the list of problems (empty = correct).
function Update-SshConfig([string[]]$HostList, [int]$Number) {
    $problems = @()
    $forward = "RemoteForward 127.0.0.1:$Number 127.0.0.1:$Number"
    Write-Step "Checking $SshConfig"
    if (-not $script:SshExe) {
        Write-Warn 'ssh.exe is not in PATH. The installer cannot verify the SSH configuration.'
    }
    $current = Read-SshConfig
    $nl = $current.Newline
    $baseText = [regex]::Replace($current.Text, $BlockPattern, '')

    # Hosts that already have the forward in the user's own entries.
    $needed = @()
    $baseFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($baseFile, $baseText, $Utf8NoBom)
    foreach ($h in $HostList) {
        $state = if ($script:SshExe) { Get-ForwardState -SshHost $h -Number $Number -ConfigFile $baseFile } else { 'missing' }
        switch ($state) {
            'ok' { Write-Note "${h}: your configuration already has the forward." }
            'conflict' {
                Write-Warn "${h}: your configuration forwards the server port $Number to a different place."
                $problems += "Fix the RemoteForward of '$h': it must be '$forward'."
            }
            'unknown' {
                Write-Warn "${h}: 'ssh -G $h' failed."
                $problems += "Fix the errors in $SshConfig (run: ssh -G $h)."
            }
            default { $needed += $h }
        }
    }
    Remove-Item $baseFile -ErrorAction SilentlyContinue

    # The block goes at the end: at the start, the global options would become
    # part of the block.
    $newText = $baseText
    $block = ''
    if ($needed.Count -gt 0) {
        $block = "# BEGIN zed-remote-open (managed by local-windows-installer.ps1, do not edit)$nl" +
            "Host $($needed -join ' ')$nl" +
            "    $forward$nl" +
            "# END zed-remote-open$nl"
        $trimmed = $baseText.TrimEnd()
        $newText = if ($trimmed) { $trimmed + $nl + $nl + $block } else { $block }
    }

    if ($newText -eq $current.Text -and -not $current.HadBom) {
        Write-Note 'No change is necessary.'
    } else {
        Write-Host ''
        if ($block) {
            Write-Host "The installer will add this block to the end of ${SshConfig}:" -ForegroundColor Cyan
            Write-Host ''
            Write-Host $block
        } else {
            Write-Host "The installer will remove the old zed-remote-open block from $SshConfig." -ForegroundColor Cyan
        }
        if ($current.HadBom) { Write-Note 'It will also remove the UTF-8 BOM at the start of the file (OpenSSH does not accept it).' }
        if (Confirm-Action "Change ${SshConfig}?" $true) {
            Write-SshConfig $newText
        } else {
            $problems += 'You did not let the installer change the file.'
        }
    }

    if ($problems.Count -eq 0 -and $script:SshExe) {
        foreach ($h in $HostList) {
            $state = Get-ForwardState -SshHost $h -Number $Number -ConfigFile ''
            if ($state -eq 'ok') {
                Write-Note "Verified: ssh $h forwards the server port $Number to 127.0.0.1:$Number."
            } else {
                $problems += "The verification of '$h' failed (state: $state). Run: ssh -G $h"
            }
        }
    }
    return , $problems
}

function Remove-SshBlock {
    $current = Read-SshConfig
    if ($current.Text -notmatch '(?m)^# BEGIN zed-remote-open') { return }
    if (Confirm-Action "Remove the zed-remote-open block from ${SshConfig}?" $true) {
        Write-SshConfig ([regex]::Replace($current.Text, $BlockPattern, ''))
    }
}

$script:SshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source

# --- Uninstall ---

if ($Uninstall) {
    Write-Step 'Uninstalling the zed-remote-open listener'
    Write-Note "This removes $InstallDir, $Shortcut and the block in $SshConfig."
    if (-not (Confirm-Action 'Continue?' $false)) { Stop-WithError 'Uninstall stopped.' }
    Stop-Listener
    Remove-Item -LiteralPath $Shortcut -ErrorAction SilentlyContinue
    Remove-SshBlock
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step 'Removed. To remove zed on the server, run there: zed --uninstall'
    exit 0
}

# --- 1. Python ---

Write-Step "Looking for pythonw.exe (Python $MinPython or later)"
if ($PythonW) {
    $candidates = @($PythonW)
} else {
    # Ignore the empty App Execution Alias files of the Microsoft Store.
    $candidates = @(Get-Command pythonw.exe -All -ErrorAction SilentlyContinue |
        Where-Object { $i = Get-Item $_.Source -ErrorAction SilentlyContinue; $i -and $i.Length -gt 0 } |
        ForEach-Object { $_.Source })
}
$pythonwExe = $null
foreach ($c in $candidates) {
    $v = Get-PythonVersion $c
    if ($v -and $v -ge $MinPython) {
        $pythonwExe = $c
        Write-Note "Found $c (Python $v)"
        break
    }
    Write-Note "Ignored $c (version: $(if ($v) { $v } else { 'unknown' }))"
}
if (-not $pythonwExe) {
    Stop-WithError ("pythonw.exe with Python $MinPython or later is not installed.`n" +
        "    Install Python from https://www.python.org/downloads/windows/ and run this script again,`n" +
        "    or give the path with -PythonW C:\path\to\pythonw.exe")
}

# --- 2. Zed ---

$zedExe = (Get-Command zed -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ($zedExe) {
    Write-Note "Found Zed: $zedExe"
} else {
    Write-Warn "The 'zed' command is not in PATH. The listener cannot open Zed without it."
}

# --- 3. Versions ---

Write-Step 'Getting the new listener'
$newFile = [IO.Path]::GetTempFileName()
$localFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'zed-listener.pyw' } else { $null }
if ($localFile -and (Test-Path $localFile)) {
    Copy-Item $localFile $newFile -Force
    Write-Note "Using $localFile"
} else {
    $url = "$BaseUrl/local/zed-listener.pyw"
    Write-Note "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $newFile
}
$newVersion = Get-ListenerVersion $newFile
if (-not $newVersion -or $newVersion -eq 'unknown') {
    Remove-Item $newFile -ErrorAction SilentlyContinue
    Stop-WithError 'The new listener file is not correct (no version).'
}
if ($newVersion -ne $InstallerVersion -and -not $Force) {
    Remove-Item $newFile -ErrorAction SilentlyContinue
    Stop-WithError ("This installer is version $InstallerVersion, but the listener is $newVersion.`n" +
        "    Use the installer and the listener of the same version: -BaseUrl " +
        "https://github.com/franciscocabral/zed-remote-open/raw/v$InstallerVersion (or use -Force).")
}
Write-Note "New version: $newVersion"

# Listener files: the install directory, the startup shortcut, and the
# listeners that run now.
$found = @($Listener)
if (Test-Path $Shortcut) {
    $found += Get-ListenerPath ((New-Object -ComObject WScript.Shell).CreateShortcut($Shortcut).Arguments)
}
$found += @(Get-ListenerProcess | ForEach-Object { Get-ListenerPath $_.CommandLine })
$found = @($found | Where-Object { $_ } | Sort-Object -Unique)

$replace = $true
foreach ($f in $found) {
    $v = Get-ListenerVersion $f
    if (-not $v) { continue }
    $isTarget = ((Resolve-Path -LiteralPath $f).Path -eq [IO.Path]::GetFullPath($Listener))
    if ($v -eq 'unknown') {
        Write-Note "Installed: $f (old version with no version number). It will be updated."
        continue
    }
    $cmp = ([version]$v).CompareTo([version]$newVersion)
    if ($cmp -lt 0) {
        Write-Note "Installed: $f ($v). It will be updated to $newVersion."
    } elseif ($cmp -eq 0) {
        if ($isTarget -and -not $Force) {
            Write-Note "Installed: $f ($v, same version). The file stays; only the settings change."
            $replace = $false
        } else {
            Write-Note "Installed: $f ($v, same version)."
        }
    } elseif ($Force) {
        Write-Warn "Installed: $f ($v) is newer than $newVersion. -Force: it will be replaced."
    } else {
        Remove-Item $newFile -ErrorAction SilentlyContinue
        Stop-WithError "The installed version $v ($f) is newer than $newVersion. Use -Force to install $newVersion."
    }
}

# The current settings are the default values.
$current = $null
if (Test-Path -LiteralPath $ConfigFile) {
    try { $current = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json } catch { $current = $null }
}

# --- 4. Stop the listeners that run now ---

Stop-Listener

# --- 5. Port ---

$portDefault = if ($current -and $current.port) { [int]$current.port } else { $DefaultPort }
$portGiven = $PSBoundParameters.ContainsKey('Port')
if (-not $portGiven) {
    $value = Read-Value 'Listener port' "$portDefault"
    $Port = if ($value -match '^\d{1,5}$') { [int]$value } else { 0 }
}
while ($true) {
    if ($Port -lt 1 -or $Port -gt 65535) {
        Write-Warn 'The port must be from 1 to 65535.'
    } elseif (-not (Test-PortFree $Port)) {
        Write-Warn "Port $Port is in use on 127.0.0.1. Select a different port."
    } else {
        break
    }
    if ($portGiven -or -not $Interactive) { exit 1 }
    $value = Read-Value 'Listener port' "$DefaultPort"
    $Port = if ($value -match '^\d{1,5}$') { [int]$value } else { 0 }
}
Write-Note "Port $Port is available."

# --- 6. Hosts ---

$hostsDefault = if ($current -and $current.hosts) { @($current.hosts) -join ',' } else { '' }
if (-not $Hosts -and -not $hostsDefault -and (Test-Path $SshConfig)) {
    $known = Select-String -Path $SshConfig -Pattern '^\s*Host\s+(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value -split '\s+' } |
        Where-Object { $_ -and $_ -notmatch '[*?!]' } | Select-Object -Unique
    if ($known) { Write-Note "Hosts in ${SshConfig}: $($known -join ', ')" }
}
$hostsGiven = [bool]$Hosts
while ($true) {
    if (-not $Hosts) { $Hosts = @(Read-Value 'SSH hosts that Zed can open (separate with commas)' $hostsDefault) }
    $Hosts = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { $_ } | Select-Object -Unique)
    $bad = @($Hosts | Where-Object { $_ -notmatch $HostPattern })
    if ($Hosts.Count -gt 0 -and $bad.Count -eq 0) { break }
    if ($bad.Count -gt 0) { Write-Warn "Not valid: $($bad -join ', '). Use only letters, digits, '.', '_' and '-'." }
    else { Write-Warn 'Give one host or more.' }
    if ($hostsGiven -or -not $Interactive) { exit 1 }
    $Hosts = $null
}

# --- 7. Token ---

$tokenValue = ''
if ($Token) {
    if ($Token -notmatch $TokenPattern) { Stop-WithError "The token is not valid (16 to 256 letters, digits, '_' or '-')." }
    $tokenValue = $Token
} elseif ($NoToken) {
    $tokenValue = ''
} elseif ($current -and $current.token) {
    $tokenValue = [string]$current.token
    Write-Note 'The current token stays (use -NoToken for no token).'
} elseif (Confirm-Action 'Use a token? Only the zed commands with the token can open files.' $true) {
    $tokenValue = New-Token
    Write-Note 'Made a new token.'
}

# --- 8. Install the listener and its settings ---

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
if ($replace) {
    Write-Step "Installing listener $newVersion in $InstallDir"
    Copy-Item $newFile $Listener -Force
}
Remove-Item $newFile -ErrorAction SilentlyContinue

$settings = [ordered]@{ port = $Port; hosts = @($Hosts) }
if ($tokenValue) { $settings.token = $tokenValue }
if ($zedExe) { $settings.zed_command = $zedExe }
[IO.File]::WriteAllText($ConfigFile, (ConvertTo-Json -InputObject $settings) + "`n", $Utf8NoBom)
Write-Note "Saved the settings in $ConfigFile"

# --- 9. Startup shortcut and start ---

$arguments = "`"$Listener`" --config `"$ConfigFile`""
if ($NoAutostart) {
    Remove-Item -LiteralPath $Shortcut -ErrorAction SilentlyContinue
} else {
    Write-Step "Creating the startup shortcut $Shortcut"
    New-Item -ItemType Directory -Force -Path (Split-Path $Shortcut) | Out-Null
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Shortcut)
    $lnk.TargetPath = $pythonwExe
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Description = 'zed-remote-open listener'
    $lnk.Save()
}

Write-Step 'Starting the listener'
Start-Process -FilePath $pythonwExe -ArgumentList $arguments -WorkingDirectory $InstallDir
Start-Sleep -Seconds 1
$response = Send-Ping -Number $Port -SshHost $Hosts[0] -TokenValue $tokenValue
if ($response -like 'OK *') {
    Write-Note "The listener answers on 127.0.0.1:$Port (version $($response.Substring(3))). Log: $LogFile"
} else {
    Write-Warn "The listener does not answer on port $Port ($response). Read $LogFile."
}

# --- 10. SSH configuration ---

$sshProblems = @()
if ($SkipSshConfig) {
    $sshProblems += 'You used -SkipSshConfig.'
} else {
    $sshProblems = Update-SshConfig -HostList $Hosts -Number $Port
}

$forwardLine = "    RemoteForward 127.0.0.1:$Port 127.0.0.1:$Port"
Write-Host ''
if ($sshProblems.Count -eq 0) {
    Write-Host '=====================================================================' -ForegroundColor Green
    Write-Host ' The SSH configuration is correct.' -ForegroundColor Green
    Write-Host '=====================================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '- Close the SSH sessions to the server and connect again. The forward'
    Write-Host '  starts only with a new connection.'
} else {
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host ' REQUIRED: change your SSH configuration. WITHOUT IT, IT WILL NOT WORK.' -ForegroundColor Red
    Write-Host '=====================================================================' -ForegroundColor Red
    $sshProblems | ForEach-Object { Write-Host "- $_" -ForegroundColor Yellow }
    Write-Host @"

Add the RemoteForward line to each host in $SshConfig :

Host $($Hosts -join ' ')
$forwardLine

- If a 'Host' entry for these names is already in the file, add only the
  RemoteForward line to it.
- Save the file as UTF-8 without a BOM.
- After the change, close the SSH sessions to the server and connect again.
"@
}
Write-Host '- Only one SSH session at a time can forward the port. The other sessions'
Write-Host '  show the warning "remote port forwarding failed". This is normal.'

$remoteCommand = "bash <(curl -fsSL $BaseUrl/remote/remote-linux-installer.sh) -y -h $($Hosts[0]) -p $Port"
if ($tokenValue) { $remoteCommand += " -k $tokenValue" }
Write-Host ''
Write-Host 'Then install the zed command on the server. Run this command there:'
Write-Host ''
Write-Host "    $remoteCommand" -ForegroundColor Cyan
Write-Host ''
if ($tokenValue) { Write-Host 'The command contains the token. Your shell can save it in its history on the server.' }
if ($Hosts.Count -gt 1) { Write-Host "The command uses the host '$($Hosts[0])'. Use -h to select a different one." }
$oldLog = Join-Path $HOME 'zed-listener.log'
if (Test-Path $oldLog) { Write-Host "The log is now $LogFile. You can delete the old log $oldLog." }
