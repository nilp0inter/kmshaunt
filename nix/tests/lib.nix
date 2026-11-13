# T4 parity harness (ROADMAP §4): every console behaviour scenario runs twice,
# once against `services.kmscon` and once against `services.kmshaunt`, on
# otherwise identical guests. A scenario that passes on kmscon must pass on
# kmshaunt.
#
# This library is a function of `pkgs` so it evaluates without nix/module.nix
# (the kmshaunt NixOS module, added in M7.3):
#
#   nix eval --impure --expr 'builtins.attrNames (import ./nix/tests/lib.nix pkgs)'
#
# How one scenario body runs against both implementations
# -------------------------------------------------------
# `mkParityTest` builds a single NixOS test with two nodes, `kmscon` and
# `kmshaunt`. `scenario` is a Nix function of a context attrset that returns a
# Python program:
#
#   ctx = {
#     machine = "kmscon" | "kmshaunt";  # guest node name
#     impl    = same as machine;        # implementation id
#     term    = "<expected $TERM>";
#     unit    = "<console unit>";
#     tty     = "tty1";
#   }
#
# The harness calls `scenario` once per node and writes the result to a .py
# file, so tracebacks point at a real file with real line numbers. The program
# runs inside the NixOS test driver with these globals injected:
#
#   machine  the guest node object (machine.succeed, machine.send_chars, ...)
#   impl     "kmscon" | "kmshaunt"
#   term     expected $TERM for that implementation
#   unit     console unit for that implementation
#   tty      "tty1"
#
# Write the scenario once and take every implementation difference from those
# variables, never from the node name. Behaviour that is correct for only one
# implementation is a parity bug: returning different Python for the two nodes
# only produces an evaluation warning, so it is visible in review.
#
# Both nodes boot together, then the program runs sequentially (kmscon first) with
# an outer subtest per implementation. An exception aborts the rest of the run,
# so steps that tear the console down (killing the unit, rebooting) go last.
#
# Deterministic screenshots
# -------------------------
# `deterministicVm` (NixOS) plus `consoleDefaults` (console config) fix the
# resolution, pin the fonts, turn cursor/text blink off and enable graphics, so
# the same guest draws the same pixels on every run (ROADMAP §4 "VM setup").
# Fonts are pinned by flake.lock: a lock bump that changes FreeType, HarfBuzz or
# the font package changes pixels, so review the image diff and regenerate the
# goldens (ROADMAP R6).
#
# `screenshotCompare` is a stub until nix/tests/goldens/ is populated. It always
# saves the screenshot into the test output; when
#   nix/tests/goldens/<test name>/<impl>/<shot>.png
# exists it also compares it, using Pillow from a host Python
# (`hostPkgs.python3.withPackages [ pillow ]`, exposed as `pillowPython`). The
# golden is a build input only when the file exists, so the harness works
# before the first golden lands.
pkgs:
let
  inherit (pkgs) lib;

  resolution = {
    x = 1024;
    y = 768;
  };

  # Pinned by flake.lock; the family name of pkgs.jetbrains-mono is
  # "JetBrains Mono" (fc-scan of JetBrainsMono-Regular.ttf).
  fontName = "JetBrains Mono";
  pinnedFonts = [ pkgs.jetbrains-mono ];

  # Every node runs the console on tty1, as systemd-logind expects.
  tty = "tty1";

  impls = [
    "kmscon"
    "kmshaunt"
  ];

  # Inline equivalent of nixos/tests/common/user-account.nix, so the harness
  # does not depend on the nixpkgs source tree.
  userAccount = {
    users.users.alice = {
      isNormalUser = true;
      description = "Alice Foobar";
      password = "foobar";
      uid = 1000;
    };
  };

  # Identical for both nodes: a scenario failure can then only come from the
  # console implementation, not from the VM.
  deterministicVm = {
    imports = [ userAccount ];
    hardware.graphics.enable = true;
    fonts.fontconfig.enable = true;
    fonts.packages = pinnedFonts;
    virtualisation.resolution = resolution;
    services.getty.autologinUser = "alice";
  };

  # Console config keys both implementations understand (D5: kmshaunt accepts
  # kmscon's option names and file syntax). Blink off keeps screenshots
  # deterministic; the font is the pinned one.
  consoleDefaults = {
    font-name = fontName;
    blink = false;
  };

  # Pillow lives in a host Python rather than in the test driver, per the
  # screenshot-compare design below.
  pillowPython = pkgs.python3.withPackages (ps: [ ps.pillow ]);

  screenshotCompareScript = pkgs.writeText "kmshaunt-screenshot-compare.py" ''
    import sys

    from PIL import Image, ImageChops

    actual_path, golden_path, max_diff = sys.argv[1], sys.argv[2], float(sys.argv[3])
    actual = Image.open(actual_path).convert("RGB")
    golden = Image.open(golden_path).convert("RGB")
    if actual.size != golden.size:
        sys.exit(f"{actual_path} is {actual.size}, {golden_path} is {golden.size}")
    total = actual.size[0] * actual.size[1]
    # Any per-channel difference counts; tobytes keeps this independent of the
    # getdata()/get_flattened_data() Pillow API churn.
    diff = ImageChops.difference(actual, golden).tobytes()
    changed = sum(1 for i in range(0, len(diff), 3) if diff[i] or diff[i + 1] or diff[i + 2])
    ratio = changed / total
    print(f"screenshot diff {ratio:.6f} ({changed}/{total} px), allowed {max_diff:.6f}")
    sys.exit(0 if ratio <= max_diff else 1)
  '';

  mkParityTest =
    {
      # Name of the NixOS test and of the golden directory:
      # nix/tests/goldens/<name>/<impl>/<shot>.png
      name,
      # ctx -> Python source; see the header for the contract.
      scenario,
      # NixOS module providing services.kmshaunt (M7.3: nix/module.nix).
      # Callers keep the import lazy, e.g. `kmshauntModule ? import ../module.nix`.
      kmshauntModule,
      kmsconPackage ? pkgs.kmscon,
      # llvmpipe (hardware.graphics.enable) is on for both nodes; hwaccel
      # selects each implementation's accelerated renderer (ROADMAP M5).
      hwaccel ? false,
      # Expected $TERM per implementation (ROADMAP D6).
      terms ? {
        kmscon = "kmscon";
        kmshaunt = "xterm-ghostty";
      },
      # Console unit per implementation: the harness kills it in the M1
      # fallback scenario.
      units ? {
        kmscon = "kmsconvt@${tty}.service";
        kmshaunt = "kmshaunt-vt@${tty}.service";
      },
      # Applied to both nodes (e.g. M5 variants: drm2d/drm3d/fbdev).
      extraConfig ? { },
      # Screenshots passed to screenshotCompare by the scenario.
      goldens ? [ ],
      goldensDir ? ./goldens,
      extraPythonPackages ? (_: [ ]),
      skipLint ? false,
      skipTypeCheck ? false,
      globalTimeout ? 60 * 60,
    }:
    let
      contextFor =
        impl:
        {
          machine = impl;
          impl = impl;
          term = terms.${impl};
          unit = units.${impl};
          tty = tty;
        };

      scenarioSources = lib.genAttrs impls (impl: scenario (contextFor impl));

      sameScenarioSource = lib.all (impl: scenarioSources.${impl} == scenarioSources.kmscon) impls;

      # One file per node: the exec'd program keeps its own line numbers in
      # tracebacks instead of pointing into a giant generated script.
      scenarioFiles = lib.mapAttrs' (
        impl: source:
        lib.nameValuePair impl (pkgs.writeText "kmshaunt-parity-${name}-${impl}.py" source)
      ) (lib.warnIf (!sameScenarioSource)
        "nix/tests/lib.nix: scenario '${name}' returns different Python for kmscon and kmshaunt; per-implementation differences belong in the injected term/unit/tty variables, not in the scenario body"
        scenarioSources
      );

      # A golden is a build input only once it exists; missing goldens keep the
      # comparison a documented stub instead of a hard failure.
      goldenPath = impl: shot: goldensDir + "/${name}/${impl}/${shot}.png";
      goldensFor =
        impl:
        lib.listToAttrs (
          map (shot: lib.nameValuePair shot "${goldenPath impl shot}") (
            lib.filter (shot: builtins.pathExists (goldenPath impl shot)) goldens
          )
        );

      kmsconNode =
        { lib, ... }:
        {
          imports = [
            deterministicVm
            extraConfig
          ];

          services.kmscon = {
            enable = true;
            package = kmsconPackage;
            config = consoleDefaults // {
              term = terms.kmscon;
              hwaccel = hwaccel;
            };
          };

          # Upstream kmsconvt@.service declares OnFailure=getty@%i.service, but
          # the nixpkgs kmscon module suppresses getty@.service, which makes the
          # M1 fallback scenario impossible on the reference implementation.
          # Restore the upstream fallback so both nodes are held to the same
          # contract: dying console unit -> getty@ttyN takes over the VT.
          systemd.suppressedSystemUnits = lib.mkForce [ ];
        };

      kmshauntNode =
        { ... }:
        {
          imports = [
            deterministicVm
            extraConfig
            kmshauntModule
          ];

          services.kmshaunt = {
            enable = true;
            config = consoleDefaults // {
              term = terms.kmshaunt;
              hwaccel = hwaccel;
            };
          };
        };
    in
    pkgs.testers.runNixOSTest {
      inherit
        name
        globalTimeout
        skipLint
        skipTypeCheck
        extraPythonPackages
        ;

      # machine.wait_for_text (OCR) is how the parity scenarios observe the VT.
      enableOCR = true;

      nodes = {
        kmscon = kmsconNode;
        kmshaunt = kmshauntNode;
      };

      testScript = ''
        import subprocess

        NAME = ${lib.strings.toJSON name};
        IMPLS = ${lib.strings.toJSON impls};
        TTY = ${lib.strings.toJSON tty};
        TERM_BY_IMPL = ${lib.strings.toJSON terms};
        UNIT_BY_IMPL = ${lib.strings.toJSON units};
        SCENARIO_BY_IMPL = ${lib.strings.toJSON scenarioFiles};
        GOLDEN_BY_IMPL = ${lib.strings.toJSON (lib.genAttrs impls goldensFor)};
        PILLOW_PYTHON = ${lib.strings.toJSON "${pillowPython}/bin/python3"};
        COMPARE_SCRIPT = ${lib.strings.toJSON "${screenshotCompareScript}"};

        def waitForLogin(machine: QemuMachine, user: str = "alice") -> None:
            """Wait until autologin produced an interactive shell on the VT.

            The process check is the reliable signal; the OCR check proves the
            prompt is actually drawn on the console, which is what a user sees.
            """
            machine.wait_for_unit("default.target")
            machine.wait_until_succeeds(f"pgrep -u {user} bash")
            machine.wait_for_text(f"{user}@")

        def screenshotCompare(
            machine: QemuMachine, impl: str, shot: str, maxDiff: float = 0.0
        ) -> None:
            """Save a screenshot and compare it with its golden, when one exists.

            Goldens live in nix/tests/goldens/<test>/<impl>/<shot>.png. While a
            golden is missing this only saves the screenshot to the test output,
            which is how new goldens are produced (copy it into the tree).
            """
            filename = f"{NAME}-{impl}-{shot}"
            machine.screenshot(filename)
            golden = GOLDEN_BY_IMPL[impl].get(shot)
            if golden is None:
                log.log(f"{filename}: no golden yet, screenshot kept in the test output")
                return
            subprocess.run(
                [
                    PILLOW_PYTHON,
                    COMPARE_SCRIPT,
                    f"{machine.out_dir}/{filename}.png",
                    golden,
                    str(maxDiff),
                ],
                check=True,
            )

        def runScenario(impl: str) -> None:
            path = SCENARIO_BY_IMPL[impl]
            with open(path, "r") as scenario:
                source = scenario.read()
            # Run the same program against this node. A copy of the driver
            # globals keeps the two runs isolated from each other while still
            # exposing subtest, log and the helpers above.
            scope = dict(globals())
            scope["machine"] = globals()[impl]
            scope["impl"] = impl
            scope["term"] = TERM_BY_IMPL[impl]
            scope["unit"] = UNIT_BY_IMPL[impl]
            scope["tty"] = TTY
            exec(compile(source, path, "exec"), scope)

        start_all()
        for impl in IMPLS:
            with subtest(f"{NAME} [{impl}]"):
                runScenario(impl)
      '';
    };
in
{
  # Deterministic VM settings shared by both parity nodes.
  inherit deterministicVm resolution fontName pinnedFonts consoleDefaults userAccount tty;

  # Host Python with Pillow, used by screenshotCompare.
  inherit pillowPython screenshotCompareScript;

  inherit mkParityTest;
}