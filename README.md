# zed-remote-open

Open files and directories of a Linux server in the Zed editor of your local
computer, from the server terminal. It is like `code .` in VS Code Remote.

Current version: <!-- version -->v1.1.0<!-- /version -->

```bash
zed .                     # open the current directory
zed README.md             # open the Git root of the file and the file, in one window
zed src/app.ts:42:5       # open a file at line 42, column 5
zed a.ts b.ts             # open more than one file
git diff | zed -          # open the text from stdin
git config --global core.editor "zed -w"   # use Zed for git commit, rebase -i, ...
export BROWSER=zed-browse # URLs of the server (gh auth login, ...) open in the local browser
make && zed --notify "build finished"      # a notification on the local computer
```

## How it works

```
Server: ~/.local/bin/zed (Bash)
  │  sends a request over TCP (protocol "zro 2")
  ▼
127.0.0.1:<port> on the server ──SSH RemoteForward──▶ 127.0.0.1:<port> on the local computer
  ▼
Local computer: zed-listener.pyw (Python, starts at login)
  │  runs: zed ssh://host/<path>  (one call for each path: the project, then its files)
  ▼
Zed opens the remote project (Zed remote development over SSH)
```

| Directory | Computer | Files |
|---|---|---|
| [`local/`](local) | The computer with Zed: Windows, macOS or Linux | `zed-listener.pyw`, `local-windows-installer.ps1`, `local-unix-installer.sh` |
| [`remote/`](remote) | Linux server | `zed`, `remote-linux-installer.sh` |

Terms in this document:

- **local**: the computer with Zed.
- **remote**: the Linux server that Zed opens with remote development.
- **host**: only the SSH host name of the remote server (the `Host` entry in
  `~/.ssh/config`, `zed -h`, and the `hosts` of the listener).

## Requirements

- **Local computer:** Zed, with the `zed` command in `PATH` (in Zed, run
  `zed: install cli` on macOS and Linux). Python 3.10 or later
  (on Windows, with `pythonw.exe` from [python.org](https://www.python.org/downloads/windows/)).
  OpenSSH client.
- **Server:** Linux, Bash 4 or later, `curl`, and `git` (optional, to find
  the Git root of a file).
- Zed must connect to the server with remote development (`zed ssh://<host>/`).
- The Zed CLI opens only one `ssh://` URL in each call. The listener runs `zed`
  one time for each path, in sequence: first the Git root, then the files.

## Installation

Do the steps in this sequence. The installers always use the files of the same
version. To install the latest release, use the URLs in
[Latest release](#latest-release).

### 1. Local computer

You can install with a package manager (see [Package managers](#package-managers))
or with the installer script.

**Windows**, in PowerShell:

```powershell
curl.exe -fsSL -o local-windows-installer.ps1 https://www.github.com/franciscocabral/zed-remote-open/raw/v1.1.0/local/local-windows-installer.ps1
powershell -ExecutionPolicy Bypass -File .\local-windows-installer.ps1
```

**macOS or Linux**, in a terminal:

```bash
bash <(curl -fsSL https://www.github.com/franciscocabral/zed-remote-open/raw/v1.1.0/local/local-unix-installer.sh)
```

The installer:

1. Makes sure that Python is 3.10 or later.
2. Compares the versions of the installed listener and the new listener
   (see [Versions](#versions)).
3. Asks for the port (default `7682`), the SSH hosts that Zed can open (for
   example `myserver`), and if you want a token (see [Token](#token)).
4. Installs the listener and its settings (`listener.json`):
   - Windows: `%LOCALAPPDATA%\zed-remote-open`
   - macOS: `~/Library/Application Support/zed-remote-open`
   - Linux: `~/.local/share/zed-remote-open`
5. Starts the listener now and at each login:
   - Windows: shortcut `zed-listener.lnk` in the Startup folder
   - macOS: launch agent `~/Library/LaunchAgents/io.github.franciscocabral.zed-remote-open.plist`
   - Linux: `~/.config/autostart/zed-remote-open.desktop`
6. Sets up the SSH tunnel: a managed tunnel, or a `RemoteForward` in
   `~/.ssh/config` (see step 2).
7. Shows the command that installs `zed` on the server, with the same options.

When the installer downloads the listener, it compares it with the
`SHA256SUMS` file of the same version. If the checksum is not correct, it stops.

Options (Windows / macOS and Linux):

| Windows | macOS, Linux | Description |
|---|---|---|
| `-Port N` | `-p N` | Listener port. |
| `-Hosts a,b` | `-H a,b` | SSH hosts that Zed can open. |
| `-Token T` | `-k T` | Use this token. |
| `-NoToken` | `-K` | Use no token. |
| `-PythonW PATH` | `-P PATH` | Python to use. |
| `-Yes` | `-y` | Ask no questions: answer yes and use the default values. |
| `-Tunnel managed` | `-T managed` | Managed SSH tunnel (see step 2). |
| `-Tunnel config` | `-T config` | `RemoteForward` in `~/.ssh/config` (see step 2). |
| `-WaitClose` | `-W` | Experimental: `zed -w` also ends when you close the tab (see [Wait mode](#use-zed-as-the-editor-of-the-server)). |
| `-Force` | `-f` | Replace a newer version, or install with a checksum that is not correct. |
| `-NoAutostart` | `-A` | Do not start the listener at login. |
| `-SkipSshConfig` | `-S` | Do not change `~/.ssh/config`. |
| `-Uninstall` | `-u` | Uninstall. |

### 2. SSH tunnel (required)

> **Without the tunnel, it does not work.** The server sends the requests
> through a reverse SSH tunnel to the listener. The installer of step 1 sets it
> up. It asks which mode to use.

#### Managed tunnel (recommended)

The listener keeps its own SSH connection to the first host, only for the
tunnel (`ssh -N -R 127.0.0.1:<port>:127.0.0.1:<port> <host>`):

- It reconnects automatically: after 2 seconds, then after longer times (at
  most 60 seconds). For example, after a network change or after the
  computer wakes from sleep.
- Your SSH sessions and Zed need no `RemoteForward`, so the warning
  `remote port forwarding failed` stops.
- It needs **SSH key authentication** with no password prompt, because the
  connection runs in the background. The installer checks this with
  `ssh -o BatchMode=yes <host> true`. If it does not work, the installer offers
  the `RemoteForward` mode.
- The installer removes its old `RemoteForward` block from `~/.ssh/config`. If
  one of your own `Host` entries has a `RemoteForward` for the port, the tunnel
  uses it, and the installer tells you to remove that line from your entry.
- The log of the tunnel is `tunnel-<host>.log`, next to `listener.log`.

#### RemoteForward in `~/.ssh/config`

The forward belongs to your SSH sessions. Each server host needs a
`RemoteForward` line in `~/.ssh/config` of the local computer. The installer
does this for you. It asks first, and then:

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

4. Keeps the line endings and the file permissions. On Windows, it writes
   UTF-8 without a BOM (OpenSSH does not accept a BOM).
5. Runs `ssh -G <host>` again to verify the result.

If you install again, the installer replaces the block. It does not add a
second block. The uninstall removes it.

To do this step manually, use `-SkipSshConfig` (Windows) or `-S` (macOS,
Linux), then add the line to the `Host` entry of each server:

```
Host myserver myserver.ts
    RemoteForward 127.0.0.1:7682 127.0.0.1:7682
```

After the change, close the SSH sessions to the server and connect again.
Only one SSH session at a time can forward the port. The other sessions show
the warning `remote port forwarding failed`. If the session with the forward
closes, the forward stops until a new session starts. The managed tunnel does
not have these problems.

### 3. Server

In an SSH session to the server, run the command that the local installer
shows. For example:

```bash
bash <(curl -fsSL https://www.github.com/franciscocabral/zed-remote-open/raw/v1.1.0/remote/remote-linux-installer.sh) -y -h myserver -p 7682 -k <token>
```

With no options, the installer asks for each value:

- **host** (`-h`): the SSH host name that the local computer uses for this
  server. It must be one of the hosts of the listener.
- **port** (`-p`): the port of the `RemoteForward` on the server (default `7682`).
- **target** (`-t`): the address of the listener (default `127.0.0.1`).
- **token** (`-k`): the token of the listener, if it has one.

Other options: `-y` (ask no questions), `-f` (replace a newer version or a
`zed` command of a different program), `-u` (uninstall).

It downloads `zed`, compares it with `SHA256SUMS` of the same version,
installs it in `~/.local/bin` with the link `zed-browse`, saves the settings,
and runs `zed --doctor` to check the connection to the listener.

If `~/.local/bin` is not in `PATH`, add this line to `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Latest release

These URLs always give the files of the latest release:

```
https://github.com/franciscocabral/zed-remote-open/releases/latest/download/local-windows-installer.ps1
https://github.com/franciscocabral/zed-remote-open/releases/latest/download/local-unix-installer.sh
https://github.com/franciscocabral/zed-remote-open/releases/latest/download/remote-linux-installer.sh
```

Each release also has a `SHA256SUMS` file.

### Package managers

**Homebrew** (macOS and Linux, local computer):

```bash
brew tap franciscocabral/zed-remote-open https://github.com/franciscocabral/zed-remote-open
brew install zed-remote-open
zed-remote-open-setup          # the installer of step 1, with the same options
```

Before `brew uninstall zed-remote-open`, run `zed-remote-open-setup -u`.

**Scoop** (Windows, local computer):

```powershell
scoop bucket add zed-remote-open https://github.com/franciscocabral/zed-remote-open
scoop install zed-remote-open
zed-remote-open-setup          # the installer of step 1, with the same options
```

`scoop uninstall zed-remote-open` also uninstalls the listener.

**winget** is not available: winget accepts only `.exe`, `.msi` and similar
installers, not a PowerShell script. A winget package needs a compiled
installer first.

The release job updates the Homebrew formula ([`Formula/`](Formula)) and the
Scoop manifest ([`bucket/`](bucket)) with the version and the checksums of
each release.

## Usage

```
zed [OPTIONS] [PATH[:LINE[:COLUMN]]...]
command | zed [OPTIONS] -
```

| Option | Description |
|---|---|
| `-w` | Wait until you save the file in Zed. Use it for `EDITOR`. |
| `-n` | Open in a new window. |
| `-a` | Open in the current window: Zed uses the window of the project if it is open (default). |
| `-p PORT` | Port of the listener. |
| `-h HOST` | SSH host name of this server. |
| `-t TARGET` | Address of the listener. |
| `-c KEY:VALUE` | Save a value in the settings file. An empty value removes the key. With `-c` and no path, `zed` opens nothing. |
| `--browse URL` | Open an `http://` or `https://` URL in the browser of the local computer. `zed-browse URL` is the same. |
| `--notify [MESSAGE]` | Show a notification on the local computer. With no MESSAGE, the text comes from stdin. |
| `--completion bash\|zsh` | Print the shell completion. |
| `--doctor` | Check the settings and the connection to the listener. |
| `--update` | Install the latest release of `zed`. |
| `--uninstall` | Remove `zed` and its settings from the server. |
| `--help`, `--version` | Show the help or the version. |

- With no path, `zed` opens the current directory.
- For a file in a Git repository, `zed` also opens the repository root. Zed
  then shows the project tree and starts the language servers for the project.
- `PATH:LINE` and `PATH:LINE:COLUMN` open the file at that position. A file
  that exists with this name is never split.
- If a path does not exist, `zed` asks before it creates it. A path that ends
  with `/` becomes a directory.
- `-` saves stdin in `~/.cache/zed-remote-open/` and opens that file. The
  files stay for 7 days.

### Use Zed as the editor of the server

```bash
git config --global core.editor "zed -w"   # for Git
export EDITOR="zed -w"                     # for other programs (crontab -e, ...)
git commit           # Zed opens COMMIT_EDITMSG; git continues when you save it
```

Git uses the first of these that is set: `GIT_EDITOR`, `core.editor`,
`VISUAL`, `EDITOR`. So `EDITOR` alone has no effect on Git if `core.editor`
or `GIT_EDITOR` is set. `git var GIT_EDITOR` shows the editor that Git uses.

With `-w`, `zed` sends only the files (not the Git root), and it waits until
you **save** one of them in Zed:

| Action | Result |
|---|---|
| Save in Zed (Ctrl+S) | `zed -w` ends with exit code 0, and Git continues. |
| Enter in the terminal | Ends with exit code 0 without a save (for example, to keep the file as it is). |
| Ctrl+C in the terminal | Ends with exit code 1: Git stops (cancel). |

Why the save and not the close of the tab: the Zed CLI cannot wait for a
remote file (`zed --wait` ends at once for `ssh://` URLs), and the server
cannot see when a tab closes.

**Experimental: end the wait when you close the tab.** Install the listener
with `-WaitClose` (Windows) or `-W` (macOS, Linux). The listener then reads
the database of Zed on the local computer and tells `zed -w` when the tab of
the file closes. The save still ends the wait too.

- It reads only (`mode=ro`). It finds the open tabs in the `items` table,
  joined with the path of the file in the `editors` table (tested with Zed
  1.27). An `editors` row stays after its tab closes, so only the join shows
  the open tabs.
- The database is internal to Zed, and a Zed update can change it. If the
  tables are not there, or the file does not appear in 20 seconds, `zed -w`
  tells you, and it waits for the save.

> If Zed autosave is on (`"autosave": "after_delay"` or `"on_focus_change"`),
> the first autosave ends the wait.

### Open URLs in the local browser

```bash
export BROWSER=zed-browse      # in ~/.zshrc or ~/.bashrc
gh auth login                  # the login page opens on the local computer
zed --browse https://example.com
```

- Only `http://` and `https://` URLs (at most 4096 characters) are accepted.
- `localhost` in a URL is the local computer, not the server. For a web server
  that runs on the server, use a port forward (for example, the port forwarding
  of Zed).

### Notifications

```bash
make && zed --notify "build finished" || zed --notify "build failed"
long-task | tail -n 1 | zed --notify          # the text from stdin
```

The title is `zed-remote-open: <host>`. The message is one line of at most
1000 characters. On the local computer:

- Windows: a Windows notification (with Windows PowerShell).
- macOS: a notification of the Notification Center (`osascript`).
- Linux: `notify-send` (install `libnotify-bin` or `libnotify`).

### Shell completion

```bash
eval "$(zed --completion zsh)"     # in ~/.zshrc, after compinit
source <(zed --completion bash)    # in ~/.bashrc
```

It completes the options, the `-c` keys and the file names.

### Settings

File: `~/.config/zed-remote-open/settings.json` (mode `600`)

```json
{
  "host": "myserver",
  "port": 7682,
  "target": "127.0.0.1",
  "token": "<token>",
  "window": "current"
}
```

| Key | Values | Environment variable |
|---|---|---|
| `host` | SSH host name of this server | `ZED_SSH_HOST` |
| `port` | 1 to 65535 (default `7682`) | `ZED_LISTENER_PORT` |
| `target` | address of the listener (default `127.0.0.1`) | `ZED_LISTENER_HOST` |
| `token` | the token of the listener | `ZED_LISTENER_TOKEN` |
| `window` | `current` (default: the window of the project if it is open) or `new` | `ZED_WINDOW` |

Precedence: option > environment variable > settings file > default value.

Examples:

```bash
zed -c window:new             # always open a new window
zed -c port:7700              # save the port
zed -c target:                # remove the target (use the default)
```

### Token

With a token, the listener accepts only the requests that have the same
token. Use it on a server with more than one user: each user of the server
can connect to the forwarded port on `127.0.0.1`.

- The local installer makes a random token (64 hexadecimal characters) and
  saves it in `listener.json`.
- The remote command of the local installer contains the token (`-k`). Your
  shell can save it in its history on the server.
- To change the token, run the local installer with `-Token`/`-k`, and then
  `zed -c token:<new token>` on the server.
- To remove it, run the local installer with `-NoToken`/`-K`, and then
  `zed -c token:` on the server.

## Versions

The version is in the `VERSION` file, in the `VERSION="X.Y.Z"` line of
`zed`, and in the `__version__ = "X.Y.Z"` line of `zed-listener.pyw`.
`zed --version` shows it, and the listener writes it to its log.

The listener sends its version in each response. If the versions of `zed`
and the listener are different, `zed` tells you which one to update.

Before they install, the installers compare the installed version with the
new version:

| Installed version | Result |
|---|---|
| Not installed, or older | Install the new version. A file with no version number is an old version. |
| Same | Keep the file. Change only the settings. |
| Newer | Stop. Use `-f`/`-Force` to install the new version. |
| A `zed` that is not from zed-remote-open (server) | Ask before it replaces the file. `-f` replaces it. |

The installers keep a copy of a replaced `zed` as `~/.local/bin/zed.bak.<date>`.

## Uninstall

- Server: `zed --uninstall`, or the remote installer with `-u`.
- Local computer: the local installer with `-Uninstall` (Windows) or `-u`
  (macOS, Linux). It stops the listener and removes its files, the autostart
  entry and the block in `~/.ssh/config`.

## Troubleshooting

Run `zed --doctor` on the server first. It shows the settings, where each
value comes from, and the result of a test request to the listener.

- **Log of the listener:** `listener.log` in the directory of step 1. It has
  each request and each rejected request with the reason, and the exit code
  and output of each `zed` call. It never contains the token.
- **Managed tunnel:** `tunnel-<host>.log` in the same directory has the
  errors of `ssh`, and `listener.log` has each connection and reconnection.
  For `Permission denied`, set up SSH key authentication for the host.
- **`cannot connect to the listener`:** the listener does not run, or the SSH
  session has no `RemoteForward`. Do steps 1 and 2 again and connect again.
- **`host '...' is not allowed`:** the host of the server is not in the hosts
  of the listener. Run the local installer again with the correct hosts, or
  change the host with `zed -c host:<name>`.
- **`invalid token`:** the token on the server is not the same as in
  `listener.json`. Use `zed -c token:<token>`.
- **`unsupported protocol`:** `zed` and the listener have incompatible
  versions. Install the same version on both computers.
- **Restart the listener:** run the local installer again. It stops the
  listener and starts it again.

## Security

- The listener accepts connections only on `127.0.0.1`.
- It accepts only the hosts in its settings and only absolute paths. If one
  line of a request is not valid, it rejects the full request.
- With a token, it accepts only requests with the same token (constant-time
  comparison).
- A request is limited to 64 KiB and 5 seconds, and the listener serves at
  most 16 connections at the same time.
- It runs `zed` without a shell. The client cannot add options to the `zed`
  command: the listener makes the command line from the fields of the request.
- It opens only `http://` and `https://` URLs. A notification is one line of
  text, and its text goes to the notification program as an argument or an
  environment variable, never as part of a command.
- The installers and `zed --update` compare each downloaded file with the
  `SHA256SUMS` of the same version. This finds a damaged or changed download.
  It does not protect against a change on GitHub itself, because
  `SHA256SUMS` comes from the same place.
- The settings files with the token have mode `600` (on Windows, they are in
  `%LOCALAPPDATA%`, which only your user can read).

## Development

- `python -m unittest discover -s tests -v`: tests of the listener and of the
  `zed` script (the end-to-end tests need Bash 4).
- `bash tests/test-unix-installer.sh`: installs both sides in a temporary
  `HOME` and tests them together.
- `tests/test-windows-installer.ps1`: the same test on Windows. It changes
  the Startup folder and `~/.ssh/config` of the current user: run it only in CI.
- To test the installers from a branch, run `scripts/update-packages.py --sums-only`,
  commit `SHA256SUMS`, and use the commit URL
  (`ZED_REMOTE_OPEN_URL=https://github.com/franciscocabral/zed-remote-open/raw/<commit>`
  or `-BaseUrl`).

### CI and releases

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on each push and
pull request:

- **lint:** ShellCheck, Ruff, PSScriptAnalyzer, and a check that the versions
  are the same in all files.
- **test-unix:** the tests on Linux (Python 3.10 and 3.13) and macOS.
- **test-windows:** the tests and the Windows installer on Windows PowerShell 5.1.

On a push to `main`, after all tests pass, the **release** job:

1. Finds the next version from the [Conventional Commits](https://www.conventionalcommits.org/)
   since the last tag: `feat` = minor, `fix`/`perf` = patch, `!` or
   `BREAKING CHANGE` = major. Other types make no release. A higher version
   in `VERSION` wins.
2. Writes the version in the files and points the download URLs in the README
   and in the installers to the new tag. Writes `SHA256SUMS`, and updates the
   Homebrew formula and the Scoop manifest (`scripts/update-packages.py`).
3. Commits `chore(release): vX.Y.Z [skip ci]`, makes the tag, and pushes both.
4. Publishes a GitHub release with the five files and `SHA256SUMS`
   (with the file names of the release).

The release commit does not start the CI again: it has `[skip ci]`, and a push
with `GITHUB_TOKEN` starts no workflow. After a release, run `git pull` before
you continue.
