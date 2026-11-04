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

Some components of Copiator are derived from Arhivar (MIT, © Berk Babadoğan),
https://github.com/berkbb/arhivar-mac-universal: the process runner, the `sandbox-exec` profile generator, the disk
space checks, quarantine propagation, open-safety helpers, the localization engine, the update checker and
signature verification, the progress overlay, the license viewer, the build, packaging and release scripts, and
the test infrastructure. The derived code is distributed as part of Copiator under GPL-3.0-only; the original
notice is kept below as the MIT license requires.

```
MIT License

Copyright (c) 2026 Berk Babadoğan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## macOS system components

- `/usr/bin/sandbox-exec`, `IOKit` (sleep assertions), `UserNotifications` and the system `libiconv` used by the
  bundled rsync are part of macOS and are not bundled.

rsync is a trademark of its respective owners. Copiator is an independent project and is not affiliated with or
endorsed by the rsync project.
