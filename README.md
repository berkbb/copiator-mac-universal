# Copiator

A native backup and sync app for macOS 26+, built with SwiftUI and Liquid Glass on top of [rsync](https://rsync.samba.org). It is built as a universal app (Apple Silicon + Intel), and a dependency-free universal rsync 3.5.1 ships inside the app bundle.

Version 1.0 copies from a local disk to a local disk. Remote servers (SSH), schedules and other engines are planned; the job model and the engine layer are already engine-independent.

## Features

- **Job queue** (like Transmission): every job has a source, a destination, options, a status (waiting, scanning, copying, paused, finished, failed), progress, speed, time left and a log. Jobs run one at a time in list order; drag to reorder.
- **Resume:** an interrupted job continues with the same command (`--partial`); only what is missing is copied. Pausing, quitting the app or a full disk never loses work.
- **Honest progress:** bytes copied, percentage, speed, time left and checked items come from rsync's `--info=progress2`. While rsync is still scanning (`ir-chk`), the row says the estimate is not final.
- **Verify:** runs the same job as a dry run (`-n -i`, optionally with checksums `-c`) and lists missing, changed and extra items. Nothing is changed.
- **Copy mode:** "copy the folder itself" (`Source` → `Destination/Source/…`) or "copy its contents" (`Source/` → `Destination/…`), with a preview of the result.
- **Safe by default:**
  - the source is never modified (`--remove-source-files` is never used; the sandbox makes the source read-only even inside the destination);
  - deleting extra files at the destination (`--delete`) only when chosen per job and confirmed;
  - rsync runs in a `sandbox-exec` sandbox with networking off, writes only to the destination and cannot read personal folders (`~/.ssh`, Keychains, browser profiles…) unless you choose them as the source;
  - jobs whose source and destination overlap are refused;
  - free space is checked before copying and watched while copying.
- **exFAT/FAT disks:** permissions, owners and ACLs are not sent to disks that cannot store them; harmless "failed to set times / permissions" warnings become one info line; FAT gets `--modify-window=1` so re-runs do not recopy everything.
- **macOS details:** system folders (`.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`…) are left out; the quarantine flag of downloaded files is kept even when extended attributes are not copied; the Mac does not idle-sleep while a job runs; a notification arrives when a job finishes.
- **Finder:** right-click › **Back Up with Copiator**, or drop a folder on the window.
- **Languages:** Turkish (default), English, Romanian. **Appearance:** Automatic, Light, Dark.
- **rsync updater:** downloads the latest release from [github.com/RsyncProject/rsync](https://github.com/RsyncProject/rsync/releases), verifies its SHA-256 and builds it on your Mac (needs the Xcode Command Line Tools).

## Installation

**Requires:** macOS 26 (Tahoe) or later. Runs on Apple Silicon and Intel Macs.

1. Download the latest `Copiator-<version>.dmg` from the [Releases](https://github.com/berkbb/copiator-mac-universal/releases) page.
2. Optionally verify the download in the folder you downloaded it to:
   ```bash
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```
3. Open the `.dmg` and drag **Copiator** into the **Applications** folder.
4. **First launch:** Copiator is ad-hoc signed rather than signed with an Apple Developer ID, so macOS shows a warning the first time. Go to **System Settings › Privacy & Security**, click **Open Anyway** next to "Copiator was blocked", and confirm.
5. On first launch, Copiator asks for permission to check GitHub for updates. You can change this later in **Settings › Advanced**.

**Finder context menu:** "Back Up with Copiator" appears under right-click › **Quick Actions** or **Services**. If it is missing, enable it in System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders.

## Development

Double-click in Finder:

- **`Paketle.command`** (package): runs the tests and produces a universal `build/Copiator.app` plus a `.dmg`, an Ed25519 signature (`.dmg.sig`) and `SHA256SUMS.txt` under `dist/`.
- **`rsync-Guncelle.command`** (update rsync): updates `Vendor/rsync` and, if present, the rsync inside `build/Copiator.app`.
- **`Yayimla.command`** (publish): shows a dry run first; if you confirm, packages the release and uploads it to GitHub Releases. GitHub Actions is not used.

The same tasks from the terminal:

```bash
./Scripts/build-rsync.sh              # build Vendor/rsync from the v3.5.1 tag (universal, /usr/lib only)
./Scripts/update-rsync.sh check       # is a newer rsync available?
./Scripts/update-rsync.sh install     # download, verify, build and install into Vendor/rsync
./Scripts/build_app.sh                # build/Copiator.app only
./Scripts/package.sh                  # tests + .app + .dmg + .dmg.sig + SHA256SUMS.txt
./Scripts/set-version.sh 1.0.1        # change the version (single source: Support/Info.plist)
./Scripts/release.sh --dry-run        # rehearse a release without sending anything
./Scripts/stress-test.sh              # pre-release stress round
swift test                            # unit, integration (real rsync), fuzz and UI-render tests
```

Requires Xcode 26 or later. See [DEVELOPMENT.md](DEVELOPMENT.md) for the architecture, [roadmap.md](.agents/context/roadmap.md) for planned features and [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

Copiator is free software under the GNU General Public License, version 3 or later ([LICENSE](LICENSE)); © Babadogan Tech and Edu. The bundled rsync is GPL-3.0-or-later as well and is run as a separate, unmodified program; its exact source, build flags and checksum are in [Vendor/rsync/SOURCE.txt](Vendor/rsync/SOURCE.txt). Some components are derived from an MIT-licensed project; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
