# T3 VM screenshot goldens (ROADMAP M3.10 + M4.6 exits, §4 T3, R6).
#
# Boots kmshaunt on the deterministic VM (nix/tests/lib.nix: fixed
# 1024x768, pinned JetBrains Mono, blink off), cats the T2 fixtures on the
# real VT and compares QMP screendumps against
# nix/tests/goldens/kmshaunt-render-golden-vm/kmshaunt/<shot>.png with the
# harness' Pillow compare (pixel-exact, maxDiff 0).
#
#   nix build .#checks.<system>.kmshaunt-render-golden-vm   # boots the VM
#
# kmshaunt-only, not a T4 parity test: kitty graphics are kmshaunt's R2
# extension, kmscon has no equivalent to compare against. The text shots
# still exercise the same fixtures as the T2 goldens (M3.10 exit: "cat of
# the same fixture matches the VM screenshot golden").
#
# Determinism notes:
# * font-size is pinned (the default 0 = auto derives the size from the
#   connector's physical mm, which is not a pixel contract).
# * The animation fixture plays once and parks on its last frame (a=a s=2),
#   so the screenshot does not race a looping animation.
# * kitten icat runs in the VT shell (send_chars), not the test backdoor:
#   its output must reach the console. TERM=xterm-kitty selects the kitty
#   protocol without terminal autodetection; the exit status is asserted
#   through a marker file.
#
# While a golden is missing the compare only saves the screenshot into the
# test output (same stub contract as nix/tests/lib.nix): run the test once,
# copy the screenshots into nix/tests/goldens/<name>/kmshaunt/, re-run.
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
let
  inherit (pkgs) lib;
  harness = import ./lib.nix pkgs;
  name = "kmshaunt-render-golden-vm";

  # The fixtures the guest cats: every T2 .bin plus the icat test PNG. Root
  # at fixtures/t2 so the files land flat in /etc/t2-fixtures/ (toSource keeps
  # paths relative to the root).
  fixtureSource = lib.fileset.toSource {
    root = ../../fixtures/t2;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (file: file.hasExt "bin") ../../fixtures/t2)
      ../../fixtures/t2/kitty-icat.png
    ];
  };

  shots = [
    "text-box-drawing"
    "text-decorations"
    "kitty-placement"
    "kitty-layers"
    "kitty-animation"
    "kitty-icat"
  ];

  # A golden is a build input only once it exists (lib.nix convention).
  goldenPath = shot: ./goldens + "/${name}/kmshaunt/${shot}.png";
  goldens = lib.listToAttrs (
    map (shot: lib.nameValuePair shot "${goldenPath shot}") (
      lib.filter (shot: builtins.pathExists (goldenPath shot)) shots
    )
  );
in
pkgs.testers.runNixOSTest {
  inherit name;
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
        config = harness.consoleDefaults // {
          term = "xterm-ghostty";
          font-size = 16;
        };
      };

      environment.systemPackages = [ pkgs.kitty.kitten ];
      environment.etc."t2-fixtures".source = fixtureSource;
    };

  testScript = ''
    import subprocess

    GOLDENS = ${lib.strings.toJSON goldens};
    PILLOW_PYTHON = ${lib.strings.toJSON "${harness.pillowPython}/bin/python3"};
    COMPARE_SCRIPT = ${lib.strings.toJSON "${harness.screenshotCompareScript}"};

    def screenshotCompare(shot: str, maxDiff: float = 0.0) -> None:
        """Save a QMP screendump and compare it with its golden, when one exists."""
        filename = f"${name}-{shot}"
        machine.screenshot(filename)
        golden = GOLDENS.get(shot)
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

    def clearScreen() -> None:
        machine.send_chars("printf '\\x1b[2J\\x1b[H'\n")
        machine.sleep(1)

    def showFixture(fixture: str, shot: str) -> None:
        machine.send_chars(f"cat /etc/t2-fixtures/{fixture}\n")
        # Let the console render the frame (and the animation settle).
        machine.sleep(1)
        screenshotCompare(shot)

    machine.wait_for_unit("default.target")
    machine.wait_until_succeeds("pgrep -u alice bash")
    machine.wait_for_text("alice@")

    with subtest("M3.10 text fixtures on the VT"):
        clearScreen()
        showFixture("box-drawing.bin", "text-box-drawing")
        clearScreen()
        showFixture("decorations.bin", "text-decorations")

    with subtest("M4.6 kitty escape fixtures on the VT"):
        clearScreen()
        showFixture("kitty-placement.bin", "kitty-placement")
        clearScreen()
        showFixture("kitty-layers.bin", "kitty-layers")
        clearScreen()
        # a=a s=2 parks on frame 2 (blue) after the 40 ms gap.
        showFixture("kitty-animation.bin", "kitty-animation")

    with subtest("M4.6 kitten icat"):
        clearScreen()
        machine.send_chars(
            "TERM=xterm-kitty kitten icat /etc/t2-fixtures/kitty-icat.png; "
            "echo icat-$? > /tmp/icat-status\n"
        )
        machine.wait_until_succeeds("grep -qx icat-0 /tmp/icat-status")
        machine.sleep(1)
        screenshotCompare("kitty-icat")
  '';
}
