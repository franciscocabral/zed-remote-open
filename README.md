# zed-remote-open

Open files and directories of a Linux server in the Zed editor of your Windows
computer, from the server terminal. It is like `code .` in VS Code Remote.

```bash
zed .                 # open the current directory
zed README.md         # open the Git root of the file and the file, in one window
zed a.ts b.ts         # open more than one file
```

## How it works

```
Linux server: ~/.local/bin/zed (Bash)
  │  sends "host:/absolute/path" lines over TCP
  ▼
127.0.0.1:<port> on the server ──SSH RemoteForward──▶ 127.0.0.1:<port> on Windows
  ▼
Windows: zed-listener.pyw (Python, started with pythonw.exe at logon)
  │  runs: zed ssh://host/<path> ...
  ▼
Zed opens the remote project (Zed remote development over SSH)
```

| Directory | Computer | Files |
|---|---|---|
| [`local/`](local) | Windows (the computer with Zed) | `zed-listener.pyw`, `local-windows-installer.ps1` |
| [`remote/`](remote) | Linux server | `zed`, `remote-linux-installer.sh` |

Terms in this document:

- **local**: the computer with Zed (Windows).
- **remote**: the Linux server that Zed opens with remote development.
- **host**: only the SSH host name of the remote server (the `Host` entry in
  `~/.ssh/config`, `zed -h`, and the listener `--hosts`).

## Requirements

- **Windows:** Zed, with the `zed` command in `PATH`. Python 3.10 or later,
  with `pythonw.exe` (from [python.org](https://www.python.org/downloads/windows/)).
  OpenSSH client.
- **Linux server:** Bash 4 or later, `curl`, and `git` (optional, to find the
  Git root of a file).
- Zed must connect to the server with remote development (`zed ssh://<host>/`).

## Installation

Do the steps in this sequence.

### 1. Windows (local)

In PowerShell:

```powershell
curl.exe -fsSL -o local-windows-installer.ps1 https://www.github.com/franciscocabral/zed-remote-open/raw/main/local/local-windows-installer.ps1
powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1
```

The installer:

1. Makes sure that `pythonw.exe` is Python 3.10 or later.
2. Asks for the port (default `7682`) and makes sure that it is available.
3. Asks for the SSH hosts that the listener allows (for example `myserver`).
4. Installs the listener in `%LOCALAPPDATA%\zed-remote-open`.
5. Creates the shortcut `zed-listener.lnk` in the Windows Startup folder and
   starts the listener.
6. Adds the `RemoteForward` to `~/.ssh/config` (see step 2).

You can also give the values as parameters:

```powershell
powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1 -Port 7682 -Hosts myserver,myserver.ts
```

The installer also finds the listeners that are already installed, in the
Startup shortcut, or running (see [Versions](#versions)).

### 2. SSH configuration on Windows (required)

> **Without this step, it does not work.** The server sends the requests
> through this SSH tunnel.

Each server host needs a `RemoteForward` line in `%USERPROFILE%\.ssh\config`.

**The installer of step 1 does this for you.** It asks first, and then:

1. Runs `ssh -G <host>` for each host. If your own entries already forward
   the port, it adds nothing for that host. If your entries forward the same
   server port to a different place, it changes nothing and tells you.
2. Makes a backup copy: `config.bak.<date>`.
3. Adds this block to the end of the file. It does not change your own
   entries. SSH uses all the `Host` entries that match a name, and the
   `RemoteForward` lines add together.

   ```
   # BEGIN zed-remote-open (managed by local-windows-installer.ps1, do not edit)
   Host myserver myserver.ts
       RemoteForward 127.0.0.1:7682 127.0.0.1:7682
   # END zed-remote-open
   ```

4. Writes UTF-8 without a BOM (OpenSSH does not accept a BOM) and keeps the
   line endings and the file permissions.
5. Runs `ssh -G <host>` again to verify the result.

If you install again, the installer replaces the block. It does not add a
second block. To remove the block, delete the lines from `# BEGIN` to
`# END`.

To do this step manually, run the installer with `-SkipSshConfig`. Then add
the `RemoteForward` line to the `Host` entry of each server:

```
Host myserver myserver.ts
    RemoteForward 127.0.0.1:7682 127.0.0.1:7682
```

After the change, close the SSH sessions to the server and connect again.

Only one SSH session at a time can forward the port. The other sessions show
the warning `remote port forwarding failed`. This is normal.

### 3. Linux server (remote)

In an SSH session to the server:

```bash
bash <(curl -fsSL https://www.github.com/franciscocabral/zed-remote-open/raw/main/remote/remote-linux-installer.sh)
```

The installer asks for:

- **host**: the SSH host name that Windows uses for this server. It must be
  one of the hosts of the listener (step 1).
- **port**: the port of the `RemoteForward` on the server (default `7682`).
- **target**: the address of the listener (default `127.0.0.1`).

It installs `zed` in `~/.local/bin`, saves the settings, and makes sure that
it can connect to the listener. It also finds the `zed` commands that are
already installed (see [Versions](#versions)). You can also give the values as options:

```bash
bash <(curl -fsSL https://www.github.com/franciscocabral/zed-remote-open/raw/main/remote/remote-linux-installer.sh) -h myserver -p 7682
```

If `~/.local/bin` is not in `PATH`, add this line to `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

```
zed [-p PORT] [-h HOST] [-t TARGET] [-c KEY:VALUE]... [PATH...]
```

| Option | Description |
|---|---|
| `-p PORT` | Port of the listener for this call. |
| `-h HOST` | SSH host name for this call. |
| `-t TARGET` | Address of the listener for this call. |
| `-c KEY:VALUE` | Save a value in the settings file. `KEY` is `host`, `port` or `target`. An empty value removes the key. With `-c` and no path, `zed` opens nothing. |
| `--help` | Show the help. |
| `--version` | Show the version. |

- With no path, `zed` opens the current directory.
- For a file in a Git repository, `zed` also opens the repository root. Zed
  then shows the project tree and starts the language servers for the project.
- If a path does not exist, `zed` asks before it creates it. A path that ends
  with `/` becomes a directory.

Examples:

```bash
zed -c port:7700              # save the port
zed -c target:                # remove the target (use the default)
zed -h myserver.ts src/main.ts
```

### Settings

File: `~/.config/zed-remote-open/settings.json`

```json
{
  "host": "myserver",
  "port": 7682,
  "target": "127.0.0.1"
}
```

Precedence: option (`-p`, `-h`, `-t`) > environment variable
(`ZED_LISTENER_PORT`, `ZED_SSH_HOST`, `ZED_LISTENER_HOST`) > settings file >
default value.

## Versions

The two components have a version number:

- `zed`: the `VERSION="X.Y.Z"` line. Show it with `zed --version`.
- `zed-listener.pyw`: the `__version__ = "X.Y.Z"` line. The listener writes
  it to the log when it starts.

Before they install, the installers compare the installed version with the
new version:

| Installed version | Result |
|---|---|
| Not installed, or older | Install the new version. A file with no version number is an old version. |
| Same | Keep the file. Change only the settings. |
| Newer | Stop. Use `-f` (Linux) or `-Force` (Windows) to install the new version. |
| A `zed` that is not from zed-remote-open (Linux) | Ask before it replaces the file, or stop without a terminal. `-f` replaces it. |

On Linux, the installer keeps a copy of the replaced file as
`~/.local/bin/zed.bak.<date>`.

## Troubleshooting

- **Log on Windows:** `%USERPROFILE%\zed-listener.log`. The listener writes
  each request, and each rejected request with the reason.
- **`cannot connect to the listener`:** the listener does not run, or the SSH
  session has no `RemoteForward`. Do steps 1 and 2 again and reconnect.
- **`Rejected request (invalid line ...)`** in the log: the host of the
  server is not in the `--hosts` of the listener. Run the Windows installer
  again with the correct hosts, or change the host with `zed -c host:<name>`.
- **Restart the listener:** stop the `pythonw.exe` process of the listener in
  Task Manager, then open the `zed-listener` shortcut in the Startup folder
  (`Win+R`, `shell:startup`).

## Security

- The listener accepts connections only on `127.0.0.1`.
- It accepts only the hosts in `--hosts` and only absolute paths. If one line
  is not valid, it rejects the full request.
- A request is limited to 64 KiB and 5 seconds.
- It runs `zed` without a shell, and it encodes each path in the URL.
- Other users of the server can connect to the forwarded port on
  `127.0.0.1` of the server. They can only make Zed open paths of the
  allowed hosts. They cannot run commands.
