# Third-Party Notices

Copiator is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation, version 3 of the License only (`GPL-3.0-only`, full text in
`LICENSE`). Copyright (C) 2026 Babadogan Tech and Edu. Copiator bundles, runs or derives from the following works.
Their license terms are listed below and are not changed by Copiator's license.

## rsync

- Authors: Andrew Tridgell, Wayne Davison and others — https://rsync.samba.org
- Source code: https://github.com/RsyncProject/rsync (the exact tag, commit, configure flags and SHA-256 of the
  bundled binary are recorded in `Vendor/rsync/SOURCE.txt`; inside the app as `rsync-SOURCE.txt`)
- License: GNU General Public License, version 3 or later, with the copyright holders' OpenSSL/xxhash linking
  exception. The full text ships with the app as `rsync-License.txt` (and next to an updated engine as `COPYING`).
- Copyright (C) 1996-2026 by Andrew Tridgell, Wayne Davison, and others.

Copiator does not link against rsync. It launches the unmodified `rsync` executable as a separate process. The
bundled binary is built from the unmodified upstream source by `Scripts/build-rsync.sh` (configure flags:
`--disable-xxhash --disable-zstd --disable-lz4 --disable-openssl --disable-md2man --disable-idn
--with-included-popt`; ACL, xattr and iconv support are enabled and come from macOS system libraries). The
corresponding source is the upstream tag named in `SOURCE.txt`; `Scripts/build-rsync.sh` rebuilds the identical
binary from it. Users can replace the executable at any time (Settings › Advanced, or `Scripts/update-rsync.sh`).

## Arhivar (derived components)

Some components of Copiator are derived from Arhivar (GNU General Public License, version 3 only, `GPL-3.0-only`;
Copyright (C) 2026 Babadogan Tech and Edu), https://github.com/berkbb/arhivar-mac-universal: the process runner, the
`sandbox-exec` profile generator, the disk space checks, quarantine propagation, open-safety helpers, the localization
engine, the update checker and signature verification, the progress overlay, the license viewer, the app log and its
Console-like log window (`AppLog`, `LogStore`, `ConsoleView`), the build, packaging and release scripts, and the test
infrastructure. Arhivar and Copiator have the same copyright holder and the same
license (`GPL-3.0-only`, `LICENSE`); the derived code is distributed as part of Copiator under GPL-3.0-only.

## Descarcator (derived components)

The Dock tile drawing (the drawn progress bar and speed pill, `DockTileView`, and the `DockProgress` tile surface) and
its tests are derived from Descarcator (GNU General Public License, version 3 only, `GPL-3.0-only`; Copyright (C) 2026
Babadogan Tech and Edu), https://github.com/berkbb/descarcator-mac-universal. Descarcator and Copiator have the same
copyright holder and the same license (`GPL-3.0-only`, `LICENSE`); the derived code is distributed as part of Copiator
under GPL-3.0-only.

## Curatare (derived components)

The Full Disk Access check (probing places only that permission opens, and the System Settings link in
`FullDiskAccess`) and the orange permission banner with its "Open System Settings" and "Later" buttons
(`PermissionBanners`) are derived from Curatare (GNU General Public License, version 3 only, `GPL-3.0-only`;
Copyright (C) 2026 Babadogan Tech and Edu), https://github.com/berkbb/curatare-mac-universal. Curatare and Copiator
have the same copyright holder and the same license (`GPL-3.0-only`, `LICENSE`); the derived code is distributed as
part of Copiator under GPL-3.0-only.

## Repository-only files (not part of the app)

The source repository also contains third-party files that are used only by coding agents working on Copiator. They
are not compiled into, bundled with, or run by Copiator.app.

### Graphify agent skill (`.claude/skills/graphify/`)

- Author: Safi Shamsi and the Graphify contributors — https://github.com/Graphify-Labs/graphify
- Files: `SKILL.md`, `references/*.md` and `.graphify_version`, copied unmodified from graphifyy 0.9.101 by
  `graphify install --project`. `CLAUDE.md`, `.claude/CLAUDE.md` and `.claude/settings.json` were also written by
  that installer.
- License: Apache License, Version 2.0; portions contributed earlier remain available under the MIT License. The full
  texts are kept next to the skill as `LICENSE` and `LICENSE-MIT`, and its notice as `NOTICE`:

```
Graphify
Copyright 2026 Safi Shamsi and the Graphify contributors.

This product is licensed under the Apache License, Version 2.0 (see LICENSE).

Portions of this software were contributed under the MIT License prior to the
relicensing and remain available under those terms. The original MIT license
text is retained in LICENSE-MIT.
```

These files keep their own license; Copiator's GPL-3.0-only does not apply to them.

## macOS system components

- `/usr/bin/sandbox-exec`, `IOKit` (sleep assertions), `UserNotifications` and the system `libiconv` used by the
  bundled rsync are part of macOS and are not bundled.

rsync is a trademark of its respective owners. Copiator is an independent project and is not affiliated with or
endorsed by the rsync project.
