# M8 performance benchmark (ROADMAP §5 M8.1/M8.3, T3/T4): ONE VM hosts both
# consoles, and the identical vtebench workload runs against each in turn.
#
#   * kmshaunt owns tty1 (it keeps the autovt@ alias, as in nix/module.nix).
#   * kmscon runs on tty2: its module's autovt@ alias is cleared (two units
#     cannot alias the same template) and the test starts kmsconvt@tty2
#     explicitly. VT switching hands DRM master between them, so only the
#     active console renders while the other idles.
#   * Both nodes of the parity harness (nix/tests/lib.nix) are collapsed into
#     this single node: same deterministicVm settings, same pinned font, same
#     resolution, same console config (sb-size=10000 for M8.3). The only
#     per-implementation differences are $TERM and the unit/tty, exactly as
#     in the T4 contract.
#
# What it measures
#   M8.1  vtebench 0.3.1 (nixpkgs) full bundled suite, default parameters
#         (--min-bytes 1048576, --max-secs 10, --warmup 1). vtebench writes
#         each sample to the console's pty and times how long the writes
#         block, i.e. how fast the console consumes terminal output. Raw
#         per-sample milliseconds land in a .dat file (--dat); throughput is
#         derived as sample_bytes / mean_ms with
#         sample_bytes = ceil(min_bytes / payload_len) * payload_len
#         (vtebench src/bench.rs Benchmark::new).
#   M8.3  peak RSS (VmHWM) of each console after `seq 1 20000` filled the
#         10,000-line scrollback, measured before the vtebench run so glyph
#         caches from the benchmark do not inflate the number.
#
# Results are written to the test output ($out): perf-summary.txt, perf.json,
# the raw <impl>.dat files, screenshots and env.txt. The build log prints the
# summary table.
#
# Wiring (modules/flake/packages.nix, same pattern as kmshaunt-m1-login):
#
#   kmshaunt-m8-perf = pkgs.callPackage ../../nix/tests/m8-perf.nix {
#     kmshauntModule = {
#       imports = [ ../../nix/module.nix ];
#       services.kmshaunt.package = config.packages.kmshaunt;
#     };
#   };
#
# Standalone (no checks wiring needed), from the repo root:
#
#   just m8-perf
#
# The kmshaunt package runs `zig build test` in its check phase. While peers'
# in-flight src edits make those tests fail, build the console binary for the
# benchmark with the check phase disabled (the installed binary is identical;
# only the unit-test gate is skipped):
#
#   services.kmshaunt.package =
#     config.packages.kmshaunt.overrideAttrs { doCheck = false; };
#
# M8.2 (damage-only presentation) is verified by reading src/video/drm2d.zig
# and src/video/drm3d.zig; the evidence is recorded in docs/perf.md. M8.4
# (real hardware) cannot run in QEMU; docs/perf.md lists what is blocked.
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
let
  inherit (pkgs) lib;
  harness = import ./lib.nix pkgs;

  # M8.3: 10,000 lines of scrollback per session, on BOTH consoles so the
  # memory numbers and the vtebench runs are directly comparable.
  consoleConfig = harness.consoleDefaults // {
    sb-size = 10000;
  };
in
pkgs.testers.runNixOSTest {
  name = "kmshaunt-m8-perf";
  enableOCR = true;

  nodes.machine =
    { ... }:
    {
      imports = [
        harness.deterministicVm
        kmshauntModule
      ];

      services.kmshaunt = {
        enable = true;
        config = consoleConfig // {
          term = "xterm-ghostty";
        };
      };

      services.kmscon = {
        enable = true;
        config = consoleConfig // {
          term = "kmscon";
        };
      };

      # One autovt@ alias only: kmshaunt keeps it (module default), kmscon
      # gives it up and is started on tty2 by the test instead.
      systemd.services."kmsconvt@".aliases = lib.mkForce [ ];
      systemd.targets.getty.wants = lib.mkForce [ "kmshaunt-vt@tty1.service" ];
      # The kmscon module suppresses getty@.service; kmshaunt's
      # OnFailure=getty@%i needs the template loadable (same override as the
      # kmscon node in nix/tests/lib.nix).
      systemd.suppressedSystemUnits = lib.mkForce [ ];
      # kmscon's login script only autologins on tty1 while autologinOnce is
      # set; the benchmark needs an interactive shell on tty2 as well.
      services.getty.autologinOnce = false;

      environment.systemPackages = [ pkgs.vtebench ];
    };

  testScript =
    { nodes, ... }:
    ''
      import datetime
      import json
      import os
      import statistics

      BENCH_DIR = "${pkgs.vtebench}/share/vtebench/benchmarks"
      MIN_BYTES = 1048576  # vtebench default --min-bytes
      OUT = machine.out_dir

      # impl -> (unit, tty, VT-switch key that activates it)
      CONSOLES = {
          "kmscon": ("kmsconvt@tty2.service", "tty2", "ctrl-alt-f2"),
          "kmshaunt": ("kmshaunt-vt@tty1.service", "tty1", "ctrl-alt-f1"),
      }


      def wait_shell(tty: str) -> None:
          """Wait until the VT is active and autologin produced a shell on it."""
          machine.wait_until_succeeds(f"test $(cat /sys/class/tty/tty0/active) = {tty}")
          machine.wait_until_succeeds(f"ps -t {tty} -u alice -o comm= | grep -qx bash")
          machine.wait_for_text("alice@")


      def switch_to(impl: str) -> None:
          unit, tty, key = CONSOLES[impl]
          machine.send_key(key)
          wait_shell(tty)


      def scrollback_rss(impl: str) -> str:
          """M8.3: fill the 10k scrollback, then read the console's peak RSS."""
          unit, tty, _ = CONSOLES[impl]
          marker = f"/tmp/sb-done-{impl}"
          machine.send_chars(f"seq 1 20000; touch {marker}\n")
          machine.wait_until_succeeds(f"test -f {marker}", timeout=datetime.timedelta(seconds=300))
          # Let the last frame render before sampling /proc.
          machine.succeed("sleep 1")
          pid = machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
          status = machine.succeed(f"cat /proc/{pid}/status")
          keep = ("VmPeak:", "VmHWM:", "VmRSS:")
          return "".join(l + "\n" for l in status.splitlines() if l.startswith(keep))


      def run_vtebench(impl: str) -> str:
          """M8.1: full vtebench suite on the active console; return the .dat.

          stdout stays on the console pty on purpose: vtebench measures how
          long writing the payload blocks, so redirecting it would measure
          nothing. The .dat file is written once, after the last benchmark.
          """
          dat = f"/tmp/{impl}.dat"
          machine.send_chars(f"vtebench --dat {dat}\n")
          # 2400 s: a slow console can exceed 15 min for the full suite
          # (kmshaunt 2026-11-13: >900 s); globalTimeout is 3600 s.
          machine.wait_until_succeeds(f"test -s {dat}", timeout=datetime.timedelta(seconds=2400))
          # Bracket trick: the driver wraps every command in `bash -c '...'`,
          # so a bare pattern would match the checking shell's own cmdline.
          machine.wait_until_succeeds("! pgrep -f 'vtebench --da[t]'", timeout=datetime.timedelta(seconds=60))
          return machine.succeed(f"cat {dat}")


      def parse_dat(text: str) -> dict:
          lines = text.strip().splitlines()
          names = lines[0].split()
          samples = {n: [] for n in names}
          for row in lines[1:]:
              for n, v in zip(names, row.split()):
                  if v != "_":
                      samples[n].append(int(v))
          return samples


      def sample_stats(vals: list) -> dict:
          s = sorted(vals)
          n = len(s)
          mean = sum(s) / n
          p90 = s[max(((n * 90 + 99) // 100) - 1, 0)]
          return {
              "samples": n,
              "mean_ms": mean,
              "median_ms": statistics.median(s),
              "p90_ms": p90,
              "min_ms": s[0],
              "max_ms": s[-1],
              "stddev_ms": statistics.stdev(s) if n > 1 else 0.0,
          }


      start_all()
      machine.wait_for_unit("default.target")

      # kmshaunt autologins on tty1 at boot.
      wait_shell("tty1")
      machine.screenshot("m8-kmshaunt-login")

      # Bring up the second console on tty2 and switch to it.
      machine.succeed("systemctl start kmsconvt@tty2.service")
      machine.wait_for_unit("kmsconvt@tty2.service")
      switch_to("kmscon")
      machine.screenshot("m8-kmscon-login")

      results = {}
      memory = {}
      grids = {}
      for impl in ("kmscon", "kmshaunt"):
          tty = CONSOLES[impl][1]
          with subtest(f"M8.3 scrollback memory [{impl}]"):
              if impl != "kmscon":
                  switch_to(impl)
              memory[impl] = scrollback_rss(impl)
              log.log(f"[{impl}] scrollback RSS:\n{memory[impl]}")
              grids[impl] = machine.succeed(f"stty -F /dev/{tty} size").strip()

          with subtest(f"M8.1 vtebench [{impl}]"):
              dat = run_vtebench(impl)
              machine.copy_from_machine(f"/tmp/{impl}.dat")
              machine.screenshot(f"m8-{impl}-vtebench-results")
              results[impl] = parse_dat(dat)

      # Sample sizes: vtebench repeats each benchmark payload until it is at
      # least MIN_BYTES (src/bench.rs Benchmark::new). The payloads are
      # deterministic scripts, so measure them once in the guest.
      payload_sizes = {}
      size_report = machine.succeed(
          f"for d in {BENCH_DIR}/*/; do "
          f"printf '%s %s\\n' \"$(basename \"$d\")\" \"$(\"$d/benchmark\" | wc -c)\"; done"
      )
      for line in size_report.strip().splitlines():
          name, size = line.split()
          payload_sizes[name] = int(size)

      env = machine.succeed(
          "uname -r; nproc; grep -m1 'model name' /proc/cpuinfo; "
          "grep MemTotal /proc/meminfo; ls /sys/class/drm; "
          "readlink /sys/class/drm/card0/device/driver; "
          "head -1 /sys/class/drm/card0-*/modes; "
          "kmshaunt --version; kmscon --version; vtebench --version"
      )
      with open(os.path.join(OUT, "env.txt"), "w") as f:
          f.write(env)

      # Throughput: bytes per sample / mean sample time. vtebench truncates
      # samples to whole milliseconds, so a 0 ms mean only yields a lower
      # bound (flagged in the JSON and shown as ">=" in the table).
      summary = {}
      for impl, benches in results.items():
          summary[impl] = {}
          for name, vals in benches.items():
              st = sample_stats(vals)
              payload = payload_sizes[name]
              size = ((MIN_BYTES - 1) // payload + 1) * payload
              mean = st["mean_ms"]
              st["sample_bytes"] = size
              st["mib_s"] = size / max(mean, 1.0) * 1000.0 / 1048576.0
              st["mib_s_lower_bound"] = mean == 0.0
              summary[impl][name] = st

      report = {
          "benchmark": "vtebench 0.3.1, default parameters "
          "(--min-bytes 1048576 --max-secs 10 --warmup 1)",
          "vm": "single NixOS VM, deterministicVm (1024x768, JetBrains Mono, "
          "blink off), drm2d on std VGA, sb-size=10000 on both consoles",
          "order": "kmscon (tty2) first, then kmshaunt (tty1)",
          "grids": grids,
          "memory": memory,
          "payload_sizes": payload_sizes,
          "results": summary,
      }
      with open(os.path.join(OUT, "perf.json"), "w") as f:
          json.dump(report, f, indent=2)

      lines = []
      lines.append("M8 performance: kmscon vs kmshaunt (same VM, same workload)")
      lines.append("")
      lines.append(f"{'benchmark':32} {'kmscon MiB/s':>14} {'kmshaunt MiB/s':>15} {'ratio':>7}")
      for name in sorted(payload_sizes):
          row = []
          for impl in ("kmscon", "kmshaunt"):
              st = summary[impl][name]
              prefix = ">=" if st["mib_s_lower_bound"] else ""
              row.append(f"{prefix}{st['mib_s']:.1f}")
          k = summary["kmscon"][name]["mib_s"]
          m = summary["kmshaunt"][name]["mib_s"]
          ratio = m / k if k > 0 else float("inf")
          lines.append(f"{name:32} {row[0]:>14} {row[1]:>15} {ratio:>7.2f}")
      lines.append("")
      for impl in ("kmscon", "kmshaunt"):
          lines.append(f"{impl} grid (rows cols): {grids[impl]}")
          lines.append(f"{impl} scrollback memory after seq 1 20000 (sb-size=10000):")
          lines.extend("  " + l for l in memory[impl].strip().splitlines())
      table = "\n".join(lines)
      with open(os.path.join(OUT, "perf-summary.txt"), "w") as f:
          f.write(table + "\n")
      log.log("\n" + table)
    '';
}