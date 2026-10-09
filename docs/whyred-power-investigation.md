# whyred idle power investigation

Read-only investigation into why `xiaomi-whyred` (Redmi Note 5, sdm636, pmOS
kernel `7.0.14-sdm660`) idles at ~670-700 mA / SoC 47-51 °C while
`xiaomi-mido` (Mi A1, msm8953) stays at ~100-300 mA / 34-38 °C.

All investigative data was gathered over SSH with strictly read-only commands
(`cat`, `ls`, `grep`, `dmesg`, `od`, live sampling with `sleep` — no writes, no
config changes). Afterwards, a **runtime-only Tier 1 mitigation** was applied
and measured (see [Tier 1 mitigation](#tier-1-mitigation-applied-runtime-only-2026-10-05));
it writes only to in-memory sysfs and does not survive a reboot.

## TL;DR

Three stacked defects, none fixable by configuration:

1. **No frequency scaling.** whyred's DT has zero cpufreq wiring and the
   subsystem never probes; CPUs are pinned at bootloader-set frequency and
   voltage forever.
2. **Firmware rejects 4 of the 5 cpuidle states the DT advertises.** Only WFI
   and `cpu-power-collapse` (PSCI ID `0x03`) ever succeed. The cluster sleep
   states (`0xF2-0xF4`) and retention (`0x02`) are refused ~16,000 times per
   second, forever.
3. **The retry loop burns the whole idle budget.** `do_idle()`'s
   `while (!need_resched())` loop re-invokes cpuidle ~1,300 times per timer
   tick, each pass re-picking the deepest state and failing. Cluster/L2 rails
   never collapse. This is the 700 mA and the 50 °C.

mido's DT advertises only `cpu-power-collapse`, its firmware accepts it, and
it reaches **99 % deep-sleep residency**.

The real fix is upstream OS-side power management for sdm636/660:
sdm660-mainline/linux issue #33 (CPRh/OSM/SPM/SAW programming).

A runtime-only workaround (disabling the rejected states) was applied and
verified on 2026-10-05: it eliminated the churn entirely, cut idle system draw
from ~700 mA to **~460 mA (−34 %)** and SoC temperatures by 10–14 °C. Details
in [Tier 1 mitigation](#tier-1-mitigation-applied-runtime-only-2026-10-05).

## Measurements

### Battery / thermal (previous session)

| metric | whyred | mido |
|---|---|---|
| SoC thermal zones | 47.5-50.7 °C | 34.8-37.6 °C |
| battery temperature | 37.8 °C | 31.5 °C |
| battery current | -567 mA | ≈ -0.15 mA (trickle) |
| suspend_stats/success | 0 (never suspended) | 0 (never suspended) |

Live re-measurement during this session: whyred discharging at **-695 to
-701 mA** sustained; mido charging/discharging under script control at
~300-500 mA.

### cpuidle state dumps (whyred, all states, cpu0 and cpu4)

| state | suspend ID | usage | rejected | verdict |
|---|---|---|---|---|
| 0: WFI | - | 367k+ | 0 | works |
| 1: pwr-retention | `0x02` | 0 | 256k | always rejected |
| 2: pwr-power-collapse | `0x03` | 670k | ~0 | works (only real sleep) |
| 3: cluster | `0xF2` | 0 | 92k | always rejected |
| 4: cluster | `0xF3` | 0 | 0 | never attempted |
| 5: cluster | `0xF4` | 0 | **1.365 billion** | always rejected |

- `current_driver=psci_idle`, governor `menu`.
- state2 accounts for only ~3 % of uptime (2,341 s of 84,000+ s).
- mido by contrast: single state `cpu-power-colla` = 81,010 s of 81,782 s
  uptime = **99 % residency**; accounting adds up.

### Live 45 s delta sampling (the decisive round)

whyred (45.1 s window):

- state5 **rejected +718,572 → 15,932 failures/second**, sustained
- state1 +280, state3 +187 — zero successes on either; state4 never attempted
- state2 usage +451, time +1.469 s → **3.3 % of the window** (the historical
  3 % gap is live, not stale)
- battery current -701 mA → -695 mA

mido (46.1 s control window):

- state1 time +45.67 s of 46.15 s = **99.0 % residency live**, +4,350
  successful entries, +63 rejections (98.7 % success)

### The accounting gap explained

`/proc/stat` says whyred is 99.8 % idle (verified live: +2,994 of +3,000
jiffies over 30 s, HZ=100), but cpuidle `time` counters account for only
~3 % of it.

Interrupt rates prove the missing time is *not* wakeups:

- arch_timer: **+73 over 30 s ≈ 2.4/s** on cpu0
- IPIs: ~10/s

So 15,932 rejections/s cannot be one-per-wakeup. Mechanism: `do_idle()`
loops `while (!need_resched())`, re-invoking `cpuidle_idle_call()` each pass.
The menu governor keeps selecting state 5 (min-residency 9.987 ms is never
satisfied because the CPU never stays asleep), PSCI rejects it (~60 µs per
failed SMC), repeat ~1,300 times per timer tick. The idle task is current
throughout, so `/proc/stat` counts all of it as "idle" while no state's `time`
counter gets credited — which is exactly the 3 % vs 99.7 % contradiction.
Kernel sys time stays at 0.1 % for the same reason.

Net effect: the cores spend ~100 % of their idle time churning failed PSCI
calls at fixed frequency with the cluster/L2 rails permanently up.

### Why the states are rejected: DT vs firmware

- DT idle-state params verified sane via `od`: entry/exit latencies 668-2336 µs,
  min-residency 9,987 µs, suspend IDs cpu `0x02/0x03`, cluster `0xF2/F3/F4`.
  So it is not bad latency numbers — **firmware refuses the state IDs**.
- `0x03` works, everything else rejected → Xiaomi's firmware implements only
  WFI + CPU power collapse.
- Boot dmesg contains no cpuidle/cpufreq failure messages beyond
  `psci: [Firmware Bug]: failed to set PC mode: -3` — which is present on
  **both** devices (whyred -3, mido -1), so it is not the differentiator.
- Upstream context: on sdm636/660 the OS is responsible for programming
  SPM/SAW/CPRh/OSM before cluster/deep states can work; mainline does not do
  this yet. Tracked at <https://github.com/sdm660-mainline/linux/issues/33>.

### Why there is no cpufreq

- `/sys/devices/system/cpu/cpu0/cpufreq` does not exist (never probed).
- DT node search (quote-safe): whyred has **no** `cpufreq`, `qcom,freq-domain`,
  `operating-points-v2`, `cpr`, `apcs`, `saw`, `spm` nodes; CPU nodes lack
  `clocks`/`power-domains`/`dynamic-power-coefficient`. mido has all of them
  (`opp-table-cpr`, clocks, power-domains, …).
- `CONFIG_CPUFREQ_DT=y`, `CPUFREQ_DT_PLATDEV=y`, `ARM_QCOM_CPUFREQ_NVMEM=m`,
  `ARM_QCOM_CPUFREQ_HW=m` are all enabled — there is simply nothing to bind to.
- `/sys/kernel/debug/clk` contains only LPASS/peripheral clocks — no
  CPU/cluster/APCS clocks are registered in the clock framework either
  (verified with a working, correctly-quoted grep; an earlier empty result was
  a PowerShell quote-stripping artifact). Actual frequency is unknowable from
  software; it is whatever the bootloader left it at.

## Tier 1 mitigation applied (runtime-only, 2026-10-05)

The rejected states can be kept out of the governor's choices at runtime via
the standard cpuidle sysfs knob (`stateN/disable`, verified present and `0` on
this kernel). Applied over SSH to **all 8 CPUs**:

```sh
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    for s in 1 3 4 5; do
        echo 1 | sudo tee "$c/cpuidle/state$s/disable"
    done
done
```

States 1 (retention), 3, 4, 5 (cluster) disabled; WFI (0) and
`cpu-power-collapse` (2) left enabled.

**Deliberately non-persistent at application time:** only in-memory sysfs was
written — no files, no services, no logs, nothing on disk. A reboot restores
every `disable` to `0`, i.e. the device returns to its original behavior.
Manual revert: write `0` back to the same files.

**Since codified in Ansible** (2026-10-05): `ansible/roles/cpuidle-fix/files/cpuidle-fix.sh`
disables states 1, 3, 4, and 5 on every CPU on `xiaomi-whyred`, both when
Ansible applies the dedicated `cpuidle-fix` role (a playbook play restricted
to `hosts: xiaomi-whyred`, so mido can never reach these tasks) and at boot
(`@reboot`). The fixed state indices
match whyred's verified layout. WFI (state 0)
and `cpu-power-collapse` (state 2) remain enabled.

### Results (before → after, same device, minutes apart)

| metric | before | after |
|---|---|---|
| rejected PSCI calls (cpu0 state5) | +718,572 per 45 s (≈15,932/s) | **+0** (frozen 28+ min, both clusters) |
| rejected (state1/state3) | +280 / +187 per 45 s | **+0 / +0** |
| power-collapse residency (state2) | 3.3 % of window | **99 %+** (44.73 s of 45.1 s; cpu4 99.6 %; 99.4 % re-verified at +28 min) |
| SoC thermal zones | 48–52 °C | **41.7–43.9 °C** within minutes → **37.5–39.8 °C** settled |
| battery current (charging state) | +207.5 mA into battery | +424.8 mA into battery (climbing as thermal throttle lifted) |
| **system draw, charger unplugged (definitive)** | **−695 … −701 mA** | **−458 … −461 mA (avg −460, 4 samples / 4.5 min)** |
| gap vs mido (34.8–37.6 °C) | ~13–14 °C | **~2–4 °C** |
| `/proc/stat` idle | 99.8 % | 99.8 % (system healthy, no lockups) |

**Definitive consumption result** (charger unplugged, `Discharging`, identical
method to the baseline): system draw fell from **~700 mA to ~460 mA — a
240 mA / 34 % reduction**, with sample spread of only 3.4 mA over 4.5 minutes.
SoC zones dropped 10–14 °C (battery zone −2…−3 °C) and were still drifting
lower when measured. The remaining gap to mido (~100–300 mA) is the known
Tier 2 territory: cluster/L2 rails never collapse and frequency never scales.

**Verdict:** everything Tier 1 could fix is fixed — the 16k/s retry churn is
gone and cores now power-collapse at every idle opportunity. Remaining gaps
(cluster/L2 never sleeps, no frequency scaling) are exactly the Tier 2 /
upstream #33 territory described below; this mitigation does not reach
mido-level idle power.

## Conclusion

mido works because its idle configuration is one shallow-but-real state that
firmware accepts, plus a fully wired cpufreq DT — 99 % deep residency,
sub-300 mA.

whyred's DT advertises a full sdm636 idle hierarchy its firmware never learned
to execute, and no cpufreq at all. The kernel dutifully retries the refused
states ~16k times per second for the lifetime of the system, never sleeps the
cluster, and never scales voltage or frequency. That is the entire ~700 mA /
50 °C idle gap.

No local configuration change fully fixes this:

- Removing/disabling the unsupported idle states from the choice set stops the
  retry churn — now measured in practice (see Tier 1 above): residency jumps
  to 99 %, system draw falls ~700 → ~460 mA (−34 %), SoC temperatures drop
  10–14 °C — but it does not enable cluster sleep or cpufreq, so parity with
  mido is still out of reach.
- The drivers for cpufreq are already compiled in; the DT/firmware support
  does not exist.

The fix is upstream: the OS-side power-management programming from
sdm660-mainline/linux#33.

## Side findings

- **GPU firmware missing:** whyred's boot log shows
  `failed to load a530_pm4.fw` on every path tried — Adreno is currently
  non-functional (separate bug from the power issue).
- **Neither device has ever suspended** (`suspend_stats/success = 0`), so
  suspend behavior was ruled out as a factor (also: no wakeup storm — whyred
  ~60 irq/s).
- **Battery cycle script works on mido:** logread shows
  `Capacity 39% <= 40%, charging` → `Capacity 62% >= 60%, discharging`;
  script at `ansible/roles/cronjobs/files/battery-cycle.sh` cycles 40-60 %.
  Caveat: `input_current_limit` writes do not stick (reads back 700000,
  not a previously written value); the `current_max` toggle is what actually
  controls charging.
- **PowerShell quote-stripping:** all remote SSH commands in this project must
  avoid embedded double quotes (PS 5.1 strips them and the remote shell then
  mangles pipes/parens). Use `''…''` inside a single-quoted PS string for
  remote quoting.
