# rsync: What Is Possible Inside the Sandbox

Copiator runs rsync in a `sandbox-exec` sandbox: networking is off, rsync can write only to the destination, the
source is read-only, and personal folders that were not chosen (`~/.ssh`, the Keychain, browser profiles, …) cannot be
read.

The rsync features in this document can be added to Copiator without relaxing these rules. All of them only need to
read the source and write to the destination. What is not possible inside the sandbox is in a separate document:
[rsync-not-possible-in-sandbox.md](rsync-not-possible-in-sandbox.md).

## 1. No sandbox change needed

### File selection

| Option | What it does |
| --- | --- |
| `--exclude`, `--include`, `--filter` | Excludes or includes files by pattern |
| `-F` | Uses `.rsync-filter` files in folders |
| `--max-size`, `--min-size` | Size limits |
| `--ignore-existing` | Leaves files that already exist at the destination alone |
| `--existing` | Updates only files that already exist at the destination |
| `-u` (`--update`) | Skips files that are newer at the destination |
| `--prune-empty-dirs` | Does not copy empty folders |

### Attributes

| Option | What it does |
| --- | --- |
| `-H` | Keeps hard links (today such files are copied separately) |
| `--crtimes`, `--atimes` | Keeps creation and access times |
| `--numeric-ids` | Maps users and groups by number instead of name |
| `--chmod` | Changes permissions at the destination |
| `-x` | Stays on one file system (skips mounted disks) |

### Symbolic links

| Option | What it does |
| --- | --- |
| `-L` | Copies the file a link points to instead of the link |
| `--copy-unsafe-links` | Copies the target of links that point outside the tree |
| `--safe-links` | Skips links that point outside the tree |

Note: with `-L`, if a link points into a protected place such as `~/.ssh`, that file is still not copied. This is a
protection, not a limitation.

### Write behavior

| Option | What it does |
| --- | --- |
| `--sparse` | Writes sparse files sparsely |
| `--inplace` | Updates files in place, without a temporary copy |
| `--append` | Transfers only data appended to the end of a file |
| `--preallocate` | Reserves disk space before writing |
| `-W` | Copies whole files without computing deltas |

### Deletion details (still confirmed per job)

| Option | What it does |
| --- | --- |
| `--delete-before`, `--delete-after`, `--delete-delay` | Deletes before, after, or in one batch at the end of the transfer |
| `--delete-excluded` | Also deletes excluded files from the destination |
| `--max-delete` | Limits how many files may be deleted |
| `--ignore-errors` | Keeps deleting even after I/O errors |

### Comparison and speed

| Option | What it does |
| --- | --- |
| `--size-only` | Compares by size only |
| `--modify-window` | Tolerance when comparing times (today automatic on FAT only) |
| `--bwlimit` | Limits the transfer rate |
| `--stop-at`, `--stop-after` | Stops at a given time or after a given duration |

### Output

| Option | What it does |
| --- | --- |
| `--stats` | Detailed transfer statistics |
| `--iconv` | Character-set conversion of file names |

### Snapshots and backup versions (as long as they stay on the destination disk)

| Option | What it does |
| --- | --- |
| `--link-dest` | Shares unchanged files with a previous backup through hard links (Time Machine-like) |
| `--compare-dest`, `--copy-dest` | Compares with a previous backup and writes only the differences |
| `--backup`, `--backup-dir`, `--suffix` | Keeps old versions of overwritten or deleted files |

rsync only reads the previous backup and only writes to the destination, so no sandbox change is needed while previous
backups and the backup folder are inside the destination disk.

## 2. Possible with a small sandbox adjustment

These options touch a single file or folder outside the destination. The sandbox gets one permission for that path only;
networking stays off and the source stays read-only.

| Option | Permission needed |
| --- | --- |
| `--files-from`, `--exclude-from`, `--include-from` | Read the list file (if it is in a personal folder) |
| `--log-file` | Write the log file (if it is outside the destination) |
| `--write-batch`, `--only-write-batch` | Write the batch file |
| `--read-batch` | Read the batch file (if it is in a personal folder) |
| `--backup-dir` (outside the destination) | Write to the backup folder |
| `--link-dest`, `--compare-dest` (outside the destination) | Read the previous backup (if it is in a personal folder) |
