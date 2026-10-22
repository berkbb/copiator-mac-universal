# rsync: What Is Not Possible Inside the Sandbox

Copiator runs rsync in a `sandbox-exec` sandbox: networking is off, rsync can write only to the destination (and to
log, batch, old-version or `--link-dest` previous-backup paths you explicitly choose in a job), the source is read-only,
and personal folders that were not chosen (`~/.ssh`, the Keychain, browser profiles, …) cannot be read.

The rsync features in this document cannot be offered without deliberately changing at least one of these rules. What
is possible inside the sandbox is in a separate document: [rsync-possible-in-sandbox.md](rsync-possible-in-sandbox.md).

## 1. Needs the network (remote transfers)

The sandbox blocks every connection with `(deny network*)`.

| Option | What it does |
| --- | --- |
| `user@host:/path`, `-e ssh` | Copies to or from another machine over SSH |
| `rsync://host/module`, `--port` | Connects to an rsync server (daemon) |
| `--daemon` | Runs as an rsync server |
| `--password-file` | Password for an rsync server |
| `-z`, `--compress-level`, `--compress-choice` | Compresses during transfer (only useful for remote transfers) |
| `--timeout`, `--contimeout` | Connection time limits |
| `--address`, `--sockopts`, `-4`, `-6` | Network address and socket settings |
| `--rsync-path` | Path of rsync on the remote side (Copiator sets it itself only for macOS's own rsync, to its own path, because openrsync starts its local receiver as a separate program) |

Remote transfers are not planned: remote (SSH) jobs were declined on 2026-10-21, so Copiator stays a local copy and sync
app and the sandbox keeps the network closed. (They would need a separate job kind, a sandbox profile that allows only that
server and running `ssh`, host key verification and credentials kept off the command line.) A network share that macOS has
mounted (SMB, AFP, NFS) is a local path and works as a source or destination.

## 2. Modifies the source

The sandbox blocks writes to the source, and the "the source is never modified" rule requires this.

| Option | What it does |
| --- | --- |
| `--remove-source-files` | Deletes copied files from the source ("move") |
| `--remove-sent-files` | Old name; same thing |

What it would take:
- Write permission for the source
- An explicit decision to change the rule (deferred for now)
- A separate confirmation for every job

## 3. Runs other programs

The sandbox does not allow running any program other than rsync itself (`deny process-exec`).

| Option | What it does |
| --- | --- |
| `-e` / `--rsh` (other than ssh) | Runs another program for the connection |
| `--rsync-path` (locally) | Runs another command on the other side |

## 4. Reaching personal folders through links

This is not a gap but a deliberate protection.

| Option | What happens in the sandbox |
| --- | --- |
| `-L`, `--copy-links`, `--copy-unsafe-links` | If a link in the source points into a protected place such as `~/.ssh` or the Keychain, that file is not copied ("Operation not permitted") |

A protected folder can be read when it is chosen explicitly as the source. The protection can be turned off entirely in
Settings › Advanced › "Run rsync in a sandbox".
