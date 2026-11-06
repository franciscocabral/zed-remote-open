<#
.SYNOPSIS
    Integration test of local-windows-installer.ps1 (runs in CI on Windows).
    It installs the listener, sends real requests, installs again, then uninstalls.
    It changes the Startup folder and ~/.ssh/config of the current user.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$installer = Join-Path $root 'local\local-windows-installer.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "zro-test-$PID"
$bin = Join-Path $work 'bin'
$calls = Join-Path $work 'zed-calls.jsonl'
$token = 'test-token-0123456789abcdef'
$python = (Get-Command python.exe).Source
$sshConfig = Join-Path $HOME '.ssh\config'
$shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'zed-listener.lnk'
$installDir = Join-Path $env:LOCALAPPDATA 'zed-remote-open'

function Test-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "ok: $Message" -ForegroundColor Green
}

function Invoke-Installer([string[]]$Arguments) {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer @Arguments 2>&1 | Out-String
    Write-Host $output
    return $output
}

# A fake "zed" command in PATH: the installer stores its path for the listener.
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Set-Content -Path (Join-Path $bin 'zed.cmd') -Encoding ASCII `
    -Value "@`"$python`" `"$(Join-Path $PSScriptRoot 'fake_zed.py')`" `"$calls`" %*"
$env:PATH = "$bin;$env:PATH"
$port = [int](& $python -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

try {
    Write-Host '### New installation'
    $out = Invoke-Installer @('-Yes', '-Port', "$port", '-Hosts', 'testhost,testhost.ts', '-Token', $token)
    Test-Condition ($out -match "The listener answers on 127\.0\.0\.1:$port") 'the listener answers'
    Test-Condition ($out -match 'Verified: ssh testhost\.ts forwards') 'ssh -G verifies the forward'
    Test-Condition ($out -match "-y -h testhost -p $port -k $token") 'the remote command has the options'
    Test-Condition (Test-Path $shortcut) 'the startup shortcut exists'
    $blocks = @(Select-String -Path $sshConfig -Pattern '^# BEGIN zed-remote-open').Count
    Test-Condition ($blocks -eq 1) 'one block in ~/.ssh/config'
    $bytes = [IO.File]::ReadAllBytes($sshConfig)
    Test-Condition (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'no BOM in ~/.ssh/config'

    Write-Host '### A real request'
    $code = "import sys; sys.path.insert(0, r'$PSScriptRoot'); from helpers import send, request; " +
        "print(send($port, request('testhost', 'open', '$token', [(3, 0, '/srv/a.md')]))[0])"
    $response = & $python -c $code
    Test-Condition ($response -like 'OK *') "the listener accepts the request ($response)"
    Start-Sleep -Seconds 2
    $last = (Get-Content $calls | Select-Object -Last 1)
    Test-Condition ($last -eq '["--add", "ssh://testhost/srv/a.md:3"]') "zed gets the correct arguments ($last)"

    Write-Host '### Same version again'
    $out = Invoke-Installer @('-Yes', '-Port', "$port", '-Hosts', 'testhost,testhost.ts')
    Test-Condition ($out -match 'same version') 'the installer finds the same version'
    Test-Condition ($out -match 'The current token stays') 'the token stays'
    Test-Condition ($out -match 'No change is necessary') 'no second SSH block'

    Write-Host '### Uninstall'
    $null = Invoke-Installer @('-Yes', '-Uninstall')
    Test-Condition (-not (Test-Path $shortcut)) 'the shortcut is removed'
    Test-Condition (-not (Test-Path $installDir)) 'the install directory is removed'
    Test-Condition (-not (Select-String -Path $sshConfig -Pattern 'zed-remote-open' -Quiet)) 'the SSH block is removed'
    $running = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*zed-listener*' })
    Test-Condition ($running.Count -eq 0) 'the listener is stopped'
    Write-Host 'All Windows installer tests passed.' -ForegroundColor Green
} finally {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*zed-listener*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
