# OHOS ELF `.codesign` — investigation, fix, and operating notes (2026-09-10)

**Scope:** why the published `openharmony-arm64` SDK had device-rejected
signatures (EPERM), how it was fixed, and the operational knowledge needed to
avoid re-treading this ground. Applies to the SDK repo's signing chain:
`OpenHarmonyCodesign.cs` (MSBuild task), `selfsign.cs` (standalone tool),
`sign-ohos-pre.py` (CI pre-signing), `install-dotnet-ohos.sh` (device install).

## 1. Mechanism (what the signature is)

- OpenHarmony/HarmonyOS executes an ELF only when it carries a valid
  `.codesign` section (fs-verity-style: 4KB section, 256-byte descriptor with
  a page-based SHA-256 Merkle root, plus a 32-byte signature; self-sign flag
  `0x10`). A signed file modified afterwards is rejected with EPERM.
- Two implementations exist and must stay in sync:
  - `src/Tasks/Microsoft.NET.Build.Tasks/OpenHarmonyCodesign.cs` — MSBuild
    task; auto-signs build outputs (`_OpenHarmonyCodesignBuildOutputs`).
  - `documentation/ohos-install/selfsign.cs` — standalone AOT tool used by CI
    pre-signing (`sign-ohos-pre.py`, linux-x64 build) and device-side
    re-signing (`install-dotnet-ohos.sh`, ohos-arm64 build).
- The two files are algorithm-identical (diff: only wrapper/namespace).

## 2. What went wrong

The published 26451.109 SDK had every ELF rejected on device:

```
$ csc
timeout: exec .../Roslyn/bincore/csc: Operation not permitted   # EPERM
```

…which broke `dotnet build`/`dotnet run` on device. Root cause: the shipped
signatures came from an **older tooling round** whose output the device
kernel refuses. The current-source algorithm produces device-valid
signatures — verified three ways on hardware:

| Path | Result |
|---|---|
| `selfsign --force` re-sign of an existing file | ✅ file runs |
| `selfsign` first-sign (append-only) of a stripped file | ✅ file runs |
| task auto-sign of a fresh AOT output | ✅ file runs |

## 3. Fix (shipped)

- `sign-ohos-pre.py` and `install-dotnet-ohos.sh` now **re-sign every ELF
  unconditionally** with `selfsign --force` instead of skipping files that
  already carry a `.codesign` section (stale signatures must be overwritten).
- `download()` gained retries/timeouts (slow links made the device-side
  selfsign fetch flaky; it falls back to binary-sign-tool).
- Commits: `ff8ac038da` (force re-sign), `db37bda313` (download retries).
- CI re-publish verified: build log `sign: 27 ELF` (was 5 — the skip is
  gone), and the republished tarball's `csc` executes on device.

## 4. Operating notes (hard-won)

1. **Never use `objcopy` on OHOS ELF files.** Any objcopy operation (even
   `--dump-section`) rewrites the file and invalidates the signature / breaks
   structure — signed files then fail with EPERM/EACCES. Use `selfsign
   --strip` instead (it rebuilds the section table in-place).
2. **Signature layout is tool-dependent.** Current algorithm on a
   previously-signed file converges to a stable size (e.g. csc: 43072 →
   47168 → 59456 → 59456 → …); re-signing is idempotent at the fixed point.
   The old selfsign produced different layouts and is **not reliable** on
   device (intermittent SIGSYS on exit / silent no-ops).
3. **Verify signatures by executing, not by inspecting.** A `.codesign`
   section can be present yet rejected. Quick check:
   `./file` (expect normal program behavior, not EPERM).
4. **`binary-sign-tool` (official) is a useful reference** — it produces the
   same layout as the current algorithm for a clean input, but it cannot
   re-sign a file that already has a section (its write-back fails with
   FILE_NOT_FOUND).
5. **Device-side selfsign build recipe** (when rebuilding the arm64 tool):
   ```sh
   cd documentation/ohos-install
   DOTNET_ROOT=$HOME/.dotnet PATH=$DOTNET_ROOT:$PATH \
     dotnet publish selfsign.csproj -c Release -r ohos-arm64 \
     -p:PublishAot=true -p:StripSymbols=false -p:CompressSymbols=false
   ```
   (Use the installed SDK whose ILCompiler pack is available; the
   `openharmony-arm64` RID needs packs that may not be cached locally.)
   The publish auto-signs its output via the task — that copy runs on device.
6. **Publish-then-modify invalidates a signature.** Any step after signing
   that rewrites an ELF (strip, objcopy, binary patching) must be followed by
   a re-sign. The install/CI flows re-sign last, after all file mutations.

## 5. Known limitations (accepted)

- Re-signing a file signed by the **old selfsign** could fail (its layout is
  no longer producible and has no real-world source; all real flows feed
  either unsigned files, task-signed files, or current-algorithm signatures —
  all verified working).
- Device-side selfsign download can be slow; retries added, falls back to
  `binary-sign-tool`.
