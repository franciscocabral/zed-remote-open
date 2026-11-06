<#
.SYNOPSIS
    Installs the zed-remote-open listener on Windows.

.DESCRIPTION
    - Makes sure that pythonw.exe (Python 3.10 or later) is installed.
    - Finds the listeners that are already installed or running and compares
      their versions with the new version. It updates an older version, keeps
      the same version, and stops for a newer version (use -Force to replace it).
    - Asks for the port and makes sure that it is available.
    - Asks for the SSH hosts that the listener allows.
    - Installs zed-listener.pyw in %LOCALAPPDATA%\zed-remote-open.
    - Creates a shortcut in the Windows Startup folder and starts the listener.
    - Adds the RemoteForward to ~/.ssh/config in a block between
      "# BEGIN zed-remote-open" and "# END zed-remote-open" markers. It asks
      before the change, keeps a backup copy, and verifies the result with
      "ssh -G". Use -SkipSshConfig to only show the lines to add.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1 -Port 7682 -Hosts myserver,myserver.ts
#>
[CmdletBinding()]
param(
    [int]$Port,
    [string[]]$Hosts,
    [string]$PythonW,
    [switch]$Force,
    [switch]$SkipSshConfig,
    [string]$BaseUrl = 'https://github.com/franciscocabral/zed-remote-open/raw/main'
)

$ErrorActionPreference = 'Stop'
$MinPython = [version]'3.10'
$DefaultPort = 7682
$InstallDir = Join-Path $env:LOCALAPPDATA 'zed-remote-open'
$Listener = Join-Path $InstallDir 'zed-listener.pyw'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'zed-listener.lnk'
$HostPattern = '^[A-Za-z0-9._-]+$'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
function Stop-WithError([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
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

# Splits a forward address from "ssh -G": "[host]:port" or "port".
function Split-Forward([string]$Text) {
    if ($Text -match '^\[(.*)\]:(\d+)$') { return @{ Host = $Matches[1]; Port = [int]$Matches[2] } }
    if ($Text -match '^(\d+)$') { return @{ Host = $null; Port = [int]$Matches[1] } }
    return $null  # Unix socket path
}

# Returns the RemoteForward entries that ssh uses for a host, or $null if
# "ssh -G" fails. -ConfigFile replaces ~/.ssh/config for the check.
function Get-RemoteForwards([string]$SshHost, [string]$ConfigFile) {
    $ErrorActionPreference = 'Continue'  # ssh writes to stderr; do not stop
    $sshArgs = @('-G')
    if ($ConfigFile) { $sshArgs += @('-F', $ConfigFile) }
    $sshArgs += $SshHost
    $out = & $sshExe @sshArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $result = @()
    foreach ($line in $out) {
        if ("$line" -match '^remoteforward\s+(\S+)\s+(\S+)') {
            $listenText = $Matches[1]
            $connectText = $Matches[2]
            $listen = Split-Forward $listenText
            $connect = Split-Forward $connectText
            if ($listen -and $connect) { $result += ,@{ Listen = $listen; Connect = $connect } }
        }
    }
    return ,$result
}

# Returns "ok" (the forward for the port is there), "conflict" (the server
# port is forwarded to a different place), "missing", or "unknown".
function Get-ForwardState([string]$SshHost, [int]$Number, [string]$ConfigFile) {
    $forwards = Get-RemoteForwards $SshHost $ConfigFile
    if ($null -eq $forwards) { return 'unknown' }
    $state = 'missing'
    foreach ($f in $forwards) {
        if ($f.Listen.Port -ne $Number) { continue }
        if ($f.Connect.Port -eq $Number -and $f.Connect.Host -in @('127.0.0.1', 'localhost')) { return 'ok' }
        $state = 'conflict'
    }
    return $state
}

function Test-PortFree([int]$Number) {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Number
    try { $l.Start(); return $true } catch { return $false } finally { $l.Stop() }
}

# --- 1. Python ---

Write-Step "Looking for pythonw.exe (Python $MinPython or later)"
$candidates = @()
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
        Write-Host "    Found $c (Python $v)"
        break
    }
    Write-Host "    Ignored $c (version: $(if ($v) { $v } else { 'unknown' }))"
}
if (-not $pythonwExe) {
    Stop-WithError ("pythonw.exe with Python $MinPython or later is not installed.`n" +
        "    Install Python from https://www.python.org/downloads/windows/ and run this script again,`n" +
        "    or give the path with -PythonW C:\path\to\pythonw.exe")
}

# --- 2. Zed ---

if (-not (Get-Command zed -ErrorAction SilentlyContinue)) {
    Write-Warn "The 'zed' command is not in PATH. The listener cannot open Zed without it."
}

# --- 3. Versions ---

Write-Step 'Getting the new listener'
$newFile = [IO.Path]::GetTempFileName()
$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'zed-listener.pyw' } else { $null }
if ($local -and (Test-Path $local)) {
    Copy-Item $local $newFile -Force
    Write-Host "    Using $local"
} else {
    $url = "$BaseUrl/local/zed-listener.pyw"
    Write-Host "    Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $newFile
}
$newVersion = Get-ListenerVersion $newFile
if (-not $newVersion -or $newVersion -eq 'unknown') {
    Remove-Item $newFile -ErrorAction SilentlyContinue
    Stop-WithError 'The new listener file is not correct (no version).'
}
Write-Host "    New version: $newVersion"

# Listener files: the install directory, the startup shortcut, and the
# listeners that run now.
$running = @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like '*zed-listener*' })
# A listener path in a command line: "C:\with spaces\zed-listener.pyw" or C:\no-spaces\zed-listener.pyw
$pyPattern = '"([A-Za-z]:\\[^"]*zed-listener[^"]*\.pyw?)"|([A-Za-z]:\\[^"\s]*zed-listener[^"\s]*\.pyw?)'
function Get-ListenerPaths([string]$Text) {
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, $pyPattern) | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
}
$found = @($Listener)
if (Test-Path $Shortcut) {
    $old = (New-Object -ComObject WScript.Shell).CreateShortcut($Shortcut).Arguments
    $found += Get-ListenerPaths $old
}
$found += @($running | ForEach-Object { Get-ListenerPaths $_.CommandLine })
$found = @($found | Where-Object { $_ } | Sort-Object -Unique)

$replace = $true
foreach ($f in $found) {
    $v = Get-ListenerVersion $f
    if (-not $v) { continue }
    $isTarget = ((Resolve-Path -LiteralPath $f).Path -eq [IO.Path]::GetFullPath($Listener))
    if ($v -eq 'unknown') {
        Write-Host "    Installed: $f (old version with no version number). It will be updated."
        continue
    }
    $cmp = ([version]$v).CompareTo([version]$newVersion)
    if ($cmp -lt 0) {
        Write-Host "    Installed: $f ($v). It will be updated to $newVersion."
    } elseif ($cmp -eq 0) {
        if ($isTarget -and -not $Force) {
            Write-Host "    Installed: $f ($v, same version). The file stays; only the settings change."
            $replace = $false
        } else {
            Write-Host "    Installed: $f ($v, same version)."
        }
    } elseif ($Force) {
        Write-Warn "Installed: $f ($v) is newer than $newVersion. -Force: it will be replaced."
    } else {
        Remove-Item $newFile -ErrorAction SilentlyContinue
        Stop-WithError "The installed version $v ($f) is newer than $newVersion. Use -Force to install $newVersion."
    }
}

# --- 4. Stop the listeners that run now ---

if ($running.Count -gt 0) {
    Write-Step 'A zed listener runs now. The installer must stop it.'
    $running | ForEach-Object { Write-Host "    PID $($_.ProcessId): $($_.CommandLine)" }
    $answer = Read-Host 'Stop it? [Y/n]'
    if ($answer -match '^[nN]') { Stop-WithError 'Installation stopped.' }
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep -Milliseconds 500
}

# --- 5. Port ---

while ($true) {
    if (-not $Port) {
        $value = Read-Host "Listener port [$DefaultPort]"
        if (-not $value) { $value = "$DefaultPort" }
        if ($value -notmatch '^\d{1,5}$') { Write-Warn "'$value' is not a number."; continue }
        $Port = [int]$value
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        Write-Warn "The port must be from 1 to 65535."
    } elseif (-not (Test-PortFree $Port)) {
        Write-Warn "Port $Port is in use on 127.0.0.1. Select a different port."
    } else {
        break
    }
    if ($PSBoundParameters.ContainsKey('Port')) { exit 1 }
    $Port = 0
}
Write-Host "    Port $Port is available."

# --- 6. Hosts ---

$sshConfig = Join-Path $HOME '.ssh\config'
if (-not $Hosts -and (Test-Path $sshConfig)) {
    $known = Select-String -Path $sshConfig -Pattern '^\s*Host\s+(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value -split '\s+' } |
        Where-Object { $_ -notmatch '[*?!]' }
    if ($known) { Write-Host "    Hosts in ${sshConfig}: $($known -join ', ')" }
}

while ($true) {
    if (-not $Hosts) {
        $value = Read-Host 'SSH hosts that Zed can open (separate with commas, for example: myserver,myserver.ts)'
        $Hosts = @($value)
    }
    $Hosts = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { $_ } | Select-Object -Unique)
    $bad = @($Hosts | Where-Object { $_ -notmatch $HostPattern })
    if ($Hosts.Count -gt 0 -and $bad.Count -eq 0) { break }
    if ($bad.Count -gt 0) { Write-Warn "Not valid: $($bad -join ', '). Use only letters, digits, '.', '_' and '-'." }
    else { Write-Warn 'Give one host or more.' }
    if ($PSBoundParameters.ContainsKey('Hosts')) { exit 1 }
    $Hosts = $null
}
$hostList = $Hosts -join ','

# --- 7. Install the listener ---

if ($replace) {
    Write-Step "Installing listener $newVersion in $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item $newFile $Listener -Force
}
Remove-Item $newFile -ErrorAction SilentlyContinue

# --- 8. Startup shortcut ---

Write-Step "Creating the startup shortcut $Shortcut"
$arguments = "`"$Listener`" --port $Port --hosts $hostList"
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($Shortcut)
$lnk.TargetPath = $pythonwExe
$lnk.Arguments = $arguments
$lnk.WorkingDirectory = $InstallDir
$lnk.Description = 'zed-remote-open listener'
$lnk.Save()

# --- 9. Start the listener ---

Write-Step 'Starting the listener'
Start-Process -FilePath $pythonwExe -ArgumentList $arguments -WorkingDirectory $InstallDir
Start-Sleep -Seconds 1
$log = Join-Path $HOME 'zed-listener.log'
if (Test-PortFree $Port) {
    Write-Warn "The listener does not listen on port $Port. Read $log."
} else {
    Write-Host "    The listener listens on 127.0.0.1:$Port (log: $log)."
}

# --- 10. SSH configuration ---

$sshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$blockRe = '(?ms)^# BEGIN zed-remote-open[^\r\n]*\r?\n.*?^# END zed-remote-open[^\r\n]*(\r?\n)?'
$forward = "RemoteForward 127.0.0.1:$Port 127.0.0.1:$Port"
$sshProblems = @()
$sshDone = $false

if ($SkipSshConfig) {
    $sshProblems += 'You used -SkipSshConfig.'
} else {
    Write-Step "Checking $sshConfig"
    if (-not $sshExe) { Write-Warn 'ssh.exe is not in PATH. The installer cannot verify the SSH configuration.' }

    # Read the file. Remove a UTF-8 BOM: OpenSSH does not accept it.
    $oldText = ''
    $hadBom = $false
    if (Test-Path -LiteralPath $sshConfig) {
        $bytes = [IO.File]::ReadAllBytes($sshConfig)
        $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $start = if ($hadBom) { 3 } else { 0 }
        $oldText = $utf8NoBom.GetString($bytes, $start, $bytes.Length - $start)
    }
    $nl = if ($oldText -match "`r`n") { "`r`n" } elseif ($oldText -match "`n") { "`n" } else { "`r`n" }

    # The file without the block of an earlier installation.
    $baseText = [regex]::Replace($oldText, $blockRe, '')

    # Hosts that already have the forward in the user's own entries.
    $needed = @()
    $baseFile = $null
    if ($sshExe) {
        $baseFile = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($baseFile, $baseText, $utf8NoBom)
    }
    foreach ($h in $Hosts) {
        $state = if ($sshExe) { Get-ForwardState $h $Port $baseFile } else { 'missing' }
        switch ($state) {
            'ok' { Write-Host "    ${h}: your configuration already has the forward." }
            'conflict' {
                Write-Warn "${h}: your configuration forwards the server port $Port to a different place."
                $sshProblems += "Fix the RemoteForward of '$h': it must be '$forward'."
            }
            'unknown' {
                Write-Warn "${h}: 'ssh -G $h' failed. Look for errors in $sshConfig."
                $sshProblems += "Fix the errors in $sshConfig (run: ssh -G $h)."
            }
            default { $needed += $h }
        }
    }
    if ($baseFile) { Remove-Item $baseFile -ErrorAction SilentlyContinue }

    # The new file: the user's text, then the block (at the end, so that the
    # global options at the start of the file stay global).
    $newText = $baseText
    if ($needed.Count -gt 0) {
        $block = "# BEGIN zed-remote-open (managed by local-windows-installer.ps1, do not edit)$nl" +
            "Host $($needed -join ' ')$nl" +
            "    $forward$nl" +
            "# END zed-remote-open$nl"
        $trimmed = $baseText.TrimEnd()
        $newText = if ($trimmed) { $trimmed + $nl + $nl + $block } else { $block }
    }

    if ($newText -eq $oldText -and -not $hadBom) {
        Write-Host '    No change is necessary.'
        $sshDone = $true
    } else {
        Write-Host ''
        if ($needed.Count -gt 0) {
            Write-Host "The installer will add this block to the end of ${sshConfig}:" -ForegroundColor Cyan
            Write-Host ''
            Write-Host $block
        } else {
            Write-Host "The installer will remove the old zed-remote-open block from $sshConfig." -ForegroundColor Cyan
        }
        if ($hadBom) { Write-Host 'It will also remove the UTF-8 BOM at the start of the file (OpenSSH does not accept it).' }
        $answer = Read-Host "Change $sshConfig? [Y/n]"
        if ($answer -match '^[nN]') {
            $sshProblems += 'You did not let the installer change the file.'
        } else {
            if (Test-Path -LiteralPath $sshConfig) {
                $backup = "$sshConfig.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
                Copy-Item -LiteralPath $sshConfig $backup
                Write-Host "    Backup: $backup"
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path $sshConfig) | Out-Null
            }
            # WriteAllText changes the file in place, so its permissions stay.
            [IO.File]::WriteAllText($sshConfig, $newText, $utf8NoBom)
            Write-Host "    Changed $sshConfig"
            $sshDone = $true
        }
    }

    # Verify the real configuration.
    if ($sshDone -and $sshExe) {
        foreach ($h in $Hosts) {
            $state = Get-ForwardState $h $Port $null
            if ($state -eq 'ok') {
                Write-Host "    Verified: ssh $h forwards the server port $Port to 127.0.0.1:$Port."
            } else {
                $sshDone = $false
                if (-not ($sshProblems | Where-Object { $_ -like "*'$h'*" })) {
                    $sshProblems += "The verification of '$h' failed (state: $state). Run: ssh -G $h"
                }
            }
        }
    }
    if ($sshProblems.Count -gt 0) { $sshDone = $false }
}

if ($sshDone) {
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Green
    Write-Host ' The SSH configuration is correct.' -ForegroundColor Green
    Write-Host '=====================================================================' -ForegroundColor Green
    Write-Host @"

- Close the SSH sessions to the server and connect again. The forward
  starts only with a new connection.
- Only one SSH session at a time can forward the port. The other sessions
  show the warning "remote port forwarding failed". This is normal.
"@
} else {
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host ' REQUIRED: change your SSH configuration. WITHOUT IT, IT WILL NOT WORK.' -ForegroundColor Red
    Write-Host '=====================================================================' -ForegroundColor Red
    $sshProblems | ForEach-Object { Write-Host "- $_" -ForegroundColor Yellow }
    Write-Host @"

Add the RemoteForward line to each host in $sshConfig :

Host $($Hosts -join ' ')
    $forward

- If a 'Host' entry for these names is already in the file, add only the
  RemoteForward line to it.
- Save the file as UTF-8 without a BOM.
- After the change, close the SSH sessions to the server and connect again.
- Only one SSH session at a time can forward the port. The other sessions
  show the warning "remote port forwarding failed". This is normal.
- To let the installer do this, run it again without -SkipSshConfig.
"@
}

Write-Host @"

The server port must be the same as the port that you give to
remote-linux-installer.sh. Install the zed command on the server:

    bash <(curl -fsSL $BaseUrl/remote/remote-linux-installer.sh)

"@
