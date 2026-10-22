# rsync: What Is Possible Inside the Sandbox

Copiator runs rsync in a `sandbox-exec` sandbox: networking is off, rsync can write only to the destination (and to
log, batch, old-version or `--link-dest` previous-backup paths you explicitly choose in a job), the source is read-only,
and personal folders that were not chosen (`~/.ssh`, the Keychain, browser profiles, …) cannot be read.

Everything in this document is available in Copiator: defaults for new jobs live in **Settings › rsync**, and each job
can change them under **Advanced rsync options** in the New Job sheet. The inspector and the New Job sheet show the exact
`rsync …` command that will run. What is not possible inside the sandbox is in a separate document:
[rsync-not-possible-in-sandbox.md](rsync-not-possible-in-sandbox.md).

## 1. No sandbox change needed

### File selection

| Option | What it does |
| --- | --- |
| `--filter`, `--include`, `--exclude` | Rules and patterns, one per line, tried in order (first match wins) |
| `-F` | Uses `.rsync-filter` files in folders |
| `--max-size`, `--min-size` | Size limits (entered in MB) |
| `--ignore-existing` | Leaves files that already exist at the destination alone |
| `--existing` | Updates only files that already exist at the destination |
| `-u` | Skips files that are newer at the destination |
| `-m` | Does not copy empty folders |

Personal folders hidden by the sandbox are always excluded before your own rules, so an `--include` cannot bring them back.

### Attributes

| Option | What it does |
| --- | --- |
| `-H` | Keeps hard links |
| `-N`, `-U` | Keeps creation and access times |
| `--numeric-ids` | Maps users and groups by number instead of name |
| `-x` | Stays on one file system |
| `--chmod` | Changes permissions at the destination (e.g. `D755,F644`) |

### Symbolic links

| Option | What it does |
| --- | --- |
| `-l` (default) | Copies links as links |
| `-L` | Copies the file a link points to |
| `--copy-unsafe-links` | Copies the target of links that point outside the tree |
| `--safe-links` | Skips links that point outside the tree |

With `-L`, a link that points into a protected place such as `~/.ssh` is still not followed (the sandbox refuses it).

### Write behavior

| Option | What it does |
| --- | --- |
| `--sparse` | Writes sparse files sparsely |
| `--inplace` | Updates files in place, without a temporary copy |
| `--append`, `--append-verify` | Transfers only data appended to the end of a file |
| `-W` | Copies whole files (already rsync's default for local copies) |

### Deletion details (only with "Delete items … not in the source", still confirmed per job)

| Option | What it does |
| --- | --- |
| `--delete-before`, `--delete-after`, `--delete-delay` | When deletions happen |
| `--delete-excluded` | Also deletes excluded files from the destination |
| `--max-delete` | Limits how many files may be deleted |
| `--ignore-errors` | Keeps deleting even after I/O errors |

### Comparison, speed and time

| Option | What it does |
| --- | --- |
| `--size-only` | Compares by size only |
| `--modify-window` | Time tolerance in seconds (FAT destinations always get at least 1) |
| `--bwlimit` | Limits the transfer rate (KB/s) |
| `--stop-after`, `--stop-at` | Stops after N minutes or at a given time; the job is paused and can be resumed |
| `--iconv` | Character-set conversion of file names (e.g. `utf-8-mac,utf-8`) |

### Snapshots that only read the previous backup

| Option | What it does |
| --- | --- |
| `--compare-dest` | Writes only files that differ from a previous backup |
| `--copy-dest` | Copies unchanged files locally from a previous backup |

### Old versions inside the destination

| Option | What it does |
| --- | --- |
| `-b`, `--suffix` | Keeps old versions of overwritten or deleted files next to them (default suffix `~`) |

### Progress and output

| Option | What it does |
| --- | --- |
| `--info=progress2` (default) | Total progress |
| `--info=progress1` | Per-file progress; the overall bar then follows the checked items |
| `--info=name1` | Shows the file being copied |
| `--no-inc-recursive` | Builds the whole list first, so percentage and time left are exact from the start |
| `--info=flist2` | Counter while the list is built (only with `--no-inc-recursive`) |
| `--info=stats2` | Statistics written to the job log at the end |
| `-i` | Every change written to the job log (the log keeps the last 500 lines) |

### List files (handled by the app)

| Option | What it does |
| --- | --- |
| `--include-from`, `--exclude-from`, `--files-from` | Read rules or file names from a list file |

rsync opens these list files one path component at a time, so a list file inside a protected folder (for example
`~/.ssh`) could only be read if the whole folder were opened. Instead, Copiator reads the list itself and gives rsync a
private temporary copy (mode 0700) that is deleted when the job ends. The protected folder stays closed.

## 2. Possible with one extra permission

These options touch a path outside the destination. The sandbox gets a permission for that path only; networking stays
off, and the source stays read-only (a path inside the source is refused).

| Option | Permission added |
| --- | --- |
| `--log-file` | Write that one file |
| `--write-batch`, `--only-write-batch` | Write the batch file and its `.sh` script |
| `--backup-dir` (outside the destination) | Write to the old-versions folder |
| `--link-dest` | Write to the previous backup |

`--link-dest` needs write access because macOS's sandbox treats creating a hard link as a write to the existing file.
Without that permission rsync silently copies instead of linking, and the snapshot uses full space. No narrower
sandbox operation covers it (tested with each individual write operation). `--compare-dest` and `--copy-dest` only read
the previous backup and get no write access.

**Copy routines** use `--files-from` the same way: the app scans the source, evaluates the routine's rules and passes the
matching paths as a private list (with `--from0`). No extra permission is needed; protected personal folders are not
scanned.

**Automatic snapshots** (New Job › Snapshots) use the same mechanism without an extra permission: the snapshot root is the
job's destination, so the previous snapshot is already writable. Copiator creates the dated `….partial` folder itself,
passes `--link-dest` to the newest complete snapshot and renames the folder when the run succeeds; retention (pruning old
snapshots) is done by the app, not by rsync.

## 3. Not offered

| Option | Why |
| --- | --- |
| `--preallocate` | This macOS build of rsync reports "no prealloc" and rejects the option |
| `--read-batch` | Not an option of a copy job but a separate operation (applying a batch file to a destination) |
