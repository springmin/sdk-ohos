# eng/ohos-install tests

Offline regression tests for the installer, the codesign contract and the shipped SDK layout.
Each `.sh` test is self-contained (no network; transports and package sources are mocked where
needed) and prints a PASS/FAIL summary:

- `test-codesign-filewrites.sh` — codesign clean contract (incremental Inputs/Outputs stamp and
  `FileWrites` registration) in `Microsoft.NET.Sdk.targets`.
- `test-hostfeed-verification.sh` — build-time hostfeed digest enforcement (H-C1), mocked transport.
- `test-installer-verification.sh` — installer download-verification hardening (D-4), mocked transport.
- `test-sdk-arch-check.sh` — SDK architecture guard around `build/check-sdk-arch.py` (prune + tarball verify).
- `test-packsplit-equivalence.sh` — stage-4 monolith vs split pipeline equivalence against stubbed
  checkouts (6 cases; recreates its scratch dir at startup, see the header for `OHOS_PACKSPLIT_*`
  env vars; the `no-tarball` case pins the fail-closed abort when the sdk build produces no
  shipping tarball).

`check-elf-codesign.py` is a standalone, offline checker for the OpenHarmony `.codesign` ELF
section (port of the runtime half of `ElfSigner.IsValidlySigned`):
`python3 eng/ohos-install/tests/check-elf-codesign.py <elf>` exits 0 only for valid files.

The two tools above were rescued from the working scratch on 2026-10-03; the inventory and the
still-unmigrated scratch scripts are recorded in
`runtime-ohos/docs/plans/2026-10-03-ohos-scratch-script-rescue.md`.
