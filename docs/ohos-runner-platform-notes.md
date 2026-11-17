# OpenHarmony self-hosted runner: platform pitfalls and gate workarounds

Observed while running the clean-machine GA gate (`ohos-clean-machine.yml`)
on an OpenHarmony arm64 host. Every item below was reproduced locally and
has a workaround in `eng/ohos-install/tests/clean-machine-ga.sh`.

## 1. Symlinked workspace produces duplicate MSBuild project identities

The runner keeps `_work` behind a symlink (`/storage/.../_work` ->
`/data/...`). MSBuild then sees one project under two spellings, evaluates
it twice and races two restores into the same `obj/` files
(`...nuget.g.props already exists`).

**Fix:** canonicalise every path once at gate start (`cd -P`) — clean root,
workload dir, NuGet packages, `GITHUB_WORKSPACE`.

## 2. Long `TMPDIR` breaks MSBuild's AF_UNIX sockets

MSBuild's server/diagnostics sockets live under `TMPDIR` and are limited to
108 bytes. A `TMPDIR` inside the clean root (~55 chars) makes every build
stall silently with no output.

**Fix:** `TMPDIR=/data/storage/el2/base/tmp/gate-tmp` (short, dedicated).

## 3. `MSBUILDDISABLENODEREUSE=1` / `-nodeReuse:false` always wedges

With node reuse disabled the runtime stalls before the first target runs
(2/2 attempts, 0 bytes of output). The supervisor used to export this, so
it leaked into the gate.

**Fix:** `unset MSBUILDDISABLENODEREUSE` in the gate; supervisor no longer
exports it. Keep the MSBuild server enabled — disabling it instead crashes
with SIGSEGV.

## 4. `ConsoleLogger` randomly throws in its constructor

```
MSBUILD : error MSB1025: An internal failure occurred while running MSBuild.
System.NullReferenceException
   at Microsoft.Build.Logging.ConsoleLogger..ctor(LoggerVerbosity verbosity)
```

It also manifests as a silent wedge, which is what made early runs look
like "no output at all".

**Fix:** build with `-noconlog` and log through the file logger.

## 5. File logger + a second writer on the same file deadlocks

Reproduced: `dotnet build ... -flp:logfile=X` while the shell also appends
to `X` hangs (rc=137, no assembly); with stdout discarded the same build
finishes in ~60 s.

**Fix:** `run_bounded_filelog` gives the file logger exclusive ownership of
`826.log.build`, discards stdout/stderr, and appends the file afterwards.
This is load-bearing: the gate only became reproducible after the logger
stopped fighting a second appending handle.

Tracked upstream: https://github.com/springmin/msbuild/issues/1
(`FileLogger deadlocks when another process appends to the same log file`).
The probe that produced the evidence lives in
`.github/workflows/ohos-runtime-repro.yml` (`dual-write file logger`), where
the ubuntu control and the OpenHarmony host are judged the same way.

## 6. `dotnet` can hang during process shutdown

Builds finish their work (assembly present, "Build succeeded" logged) but
the process never exits, and SIGTERM is not delivered. A watchdog that
waits for exit always "fails".

**Fix:** judge success by artifacts (`verify.dll`, `[suite]` line, `.hap`),
run bounded steps in their own process group with `setsid`, and SIGKILL
after a stall/timeout. Suite runs go through a pty (`script -q -c`) so
output is line-flushed.

## 7. Canceled runs leave setsid builds behind

They escape the listener's process-group kill, keep spinning and hold the
same `obj/` directory, so every later attempt stalls.

**Fix:** reap any `dotnet build|publish` whose cwd is inside the workspace
before starting the harness.

## Residual issue: builds only wedge inside the runner process tree

The identical command, environment and paths build in ~60 s from a plain
shell (including the supervisor's `DOTNET_*`/`GITHUB_*`/`RUNNER_*` vars),
but stalls in the worker's process tree after `ResolvePackageAssets`.
`826.log.build` never receives a single byte, so the wedge is before the
logger starts.

**Workaround:** `prebuilt_826=true` — build `verify.dll` from a plain shell,
copy `bin/` to `$CLEAN_ROOT/prebuilt/826/`, and let the gate restore it and
run only the suite. Extend the same pattern to JIT/AOT if needed.

## Evidence

* 826 suite passed once end-to-end on the runner: run `43721271686`,
  `[suite] checks=826 total=829 floor=809 assert=True`.
* Local proof that the wedge is context-specific: same command, same env,
  `dll=yes` in ~60 s (multiple runs).

## Baseline evidence (GA gate green)

| Gate | Evidence |
|---|---|
| 826 suite | run `43971774215`: `[suite] checks=826 total=829 floor=809 assert=True` |
| JIT publish | same run: `OpenHarmony: signed`, hap hash pin matched |
| AOT publish | same run: `EXIT=0`, IL2026/IL3050/IL3051 = 0, `publish/libhello-maui-app.so` present |
| Device round | run `43977174295`: success; archive `_work/_temp/device-round-20261117-072206.tar.gz` |

The `prebuilt_826` / `prebuilt_jit` / `prebuilt_aot` switches are a
WORKAROUND for the runner-side MSBuild wedge above. Remove them (and the
prebuilt validation run) once builds work inside the runner process tree.

Device rounds additionally depend on the device being reachable: the
workflow now runs `hdc tconn <device>` when `hdc list targets` is empty.

## Operations: a wedged runner session

Symptom: the runner shows `online` with `busy=false`, jobs stay `queued`
forever, and `_diag/supervisor.log` repeats:

```
√ Connected to GitHub
A session for this runner already exists.
```

Cause: a job was killed (cancel, watchdog, host restart) and GitHub still
holds the session; the listener cannot claim a new one. Killing listeners or
restarting the supervisor does *not* clear it (verified).

Recovery (keeps `bin/` patches and `_work` intact):

```bash
cd /storage/Users/currentUser/actions-runner-fd
tok=$(gh api -X POST repos/springmin/sdk-ohos/actions/runners/registration-token --jq .token)
./config.sh remove --token "$tok"
./config.sh --url https://github.com/springmin/sdk-ohos --token "$tok" \
  --name ohos-arm64-01 --labels self-hosted,openharmony,ohos-arm64 \
  --work _work --unattended --replace
# restart the supervisor (the old one holds a dead session)
rm -rf .supervisor.lock && setsid ./supervise.sh >> _diag/supervisor.log 2>&1 < /dev/null &
```

`judge-watchdog.sh` (host-side, started once per boot) automates this: every
`INTERVAL` seconds it looks for queued runs older than `STALE` while the
runner is `online`/`busy=false`, and then re-registers + restarts the
supervisor. A workflow-based watchdog cannot help here, because its own job
would queue behind the wedged session.

Scheduled workflows: `schedule` only fires for workflows on the **default
branch** (`feature/openharmony` here) and GitHub treats cron as best effort.
If no run with `event=schedule` shows up after 18:00 UTC, enable scheduled
workflows for the fork under Settings -> Actions (forked repositories can have
them disabled, which the API does not report as `disabled_manually`).
