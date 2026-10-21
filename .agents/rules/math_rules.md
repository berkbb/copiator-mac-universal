# Mathematical, Byte-Counting & Physical Invariants

- **Source:** Project Domain Invariants (`CopiatorCore`)
- **Version:** 1.0.0
- **Last Review Date:** 2026-10-21
- **Change Summary:** Initial Copiator invariants: saturating sums, volume-scaled disk reserve and floor, rsync progress unit conversions, throttling, FAT timestamp window.

---

## 1. Saturating `Int64` Byte Arithmetic

- **Rule:** Never sum file sizes with unchecked `+`. Use `Int64.saturatingAdding(_:)` / `Sequence<Int64>.saturatingSum()` (`DiskSpace.swift`).
- $$\text{saturatingAdd}(a, b) = \min(\max(a + b, \text{Int64.min}), \text{Int64.max})$$
- Parsed byte counts larger than `Int64.max` clamp to `Int64.max` (`RsyncProgressParser.parseBytes`).

## 2. Disk Space (`DiskSpace`, `DiskSpaceGuard`)

1. **Required bytes for a copy:** $$\text{Required} = \max(0,\ \text{SourceBytes} - \max(0, \text{ExistingCounterpartBytes}))$$ where counterparts are `destination/Name` (folder mode) or the destination items named like the source's top-level items (contents mode).
2. **Reserve scaled to the volume:** $$\text{Reserve}(C) = \begin{cases} 2^{30} & C \text{ unknown or } \le 0 \\ \min(2^{30},\ \lfloor C / 50 \rfloor) & \text{otherwise} \end{cases}$$
3. **Room check:** $$\text{hasRoom} \iff \text{Required} \le \max(0,\ \text{Available} - \text{Reserve})$$ — unknown availability never blocks.
4. **In-copy floor:** $$\text{Floor}(C) = \text{Reserve}(C) / 2$$ (512 MiB on volumes ≥ 51.2 GB). Free space below the floor stops rsync (`InsufficientSpaceError.stoppedWhileWriting`).

## 3. rsync Progress Units (`RsyncProgressParser`)

- Bytes with `-h` (human-readable level 2) are **1000-based**: `K = 10^3`, `M = 10^6`, `G = 10^9`, `T = 10^12`, `P = 10^15`; without a suffix, separators (`,` `.` `_` `'`) are stripped.
- Rates are **1024-based**: `kB/s = 1024`, `MB/s = 1024^2`, `GB/s = 1024^3` bytes per second.
- Time `H:MM:SS` → $3600H + 60M + S$ with $0 \le M,S < 60$, $H \le 9999$; `??:??:??` → unknown.
- $\text{fraction} = \text{pct} / 100$, valid only for $0 \le \text{pct} \le 100$; `itemsChecked = max(0, total − remaining)`.

## 4. Throttling and Time Windows

- Progress events: at most one per `RsyncEngine.progressInterval` (0.25 s) plus immediate events on `ir-chk` ↔ `to-chk` transitions and a final flush.
- Progress is persisted at most every 5 s; status and log changes are persisted immediately.
- FAT stores modification times in 2-second steps: FAT destinations get `--modify-window=1`; quarantine freshness checks allow a 2-second skew.
