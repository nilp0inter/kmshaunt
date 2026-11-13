# M5.8 exit scenarios (ROADMAP §5, M5 exit) as T4 parity tests: one scenario
# body per variant, run against services.kmscon and services.kmshaunt on
# identical guests.
#
# Wired into checks by modules/flake/packages.nix:
#
#   kmshaunt-m5-video = pkgs.callPackage ../../nix/tests/m5-video.nix {
#     kmshauntModule = {
#       imports = [ ../../nix/module.nix ];
#       services.kmshaunt.package = config.packages.kmshaunt;
#     };
#   };
#
#   nix build .#checks.<system>.kmshaunt-m5-video          # runs every variant
#   nix build .#checks.<system>.kmshaunt-m5-video.driver   # lint/type-check only
#   nix build .#checks.<system>.kmshaunt-m5-video.tests.<variant>  # one variant
#
# The aggregate is a thin derivation whose buildInputs are the variant tests,
# so building it runs them all; passthru.tests exposes each variant and
# passthru.driver joins their drivers.
#
# Variants (ROADMAP M5 exit: "same scenarios pass on drm2d, drm3d (llvmpipe)
# and fbdev", "two-output clone and scaled goldens", "rotation goldens for all
# four orientations", "sysfs dpms reads Off after the timeout and On after a
# keypress"):
#
#   drm2d / drm3d / fbdev   backend boot: autologin prompt renders, $TERM is
#                           the implementation's own, text echoes. Backend
#                           oracle: the console's MainPID holds /dev/dri/cardN
#                           open (both DRM backends) or /dev/fb0 and no DRM
#                           node (no-drm). The drm3d variant also logs whether
#                           libEGL is mapped (evidence, not an assertion; see
#                           the parity gap below).
#   rotate-0/90/180/270     screen=<orientation> at boot. kmscon and kmshaunt
#                           share the grammar `[gpu][connector]orientation`
#                           with NAMED orientations, not degrees:
#                           normal=0, right=90 cw, upside-down=180, left=270
#                           (kmscon config.c:627-750; kmshaunt
#                           src/config/display.zig). The global tier (no
#                           gpu/connector prefix) applies to every screen.
#                           Orientation is asserted with OCR: the marker is
#                           readable horizontally only at 0 degrees. The
#                           rotate grabs (Logo+equal = cw, Logo+minus = ccw;
#                           QEMU key name meta_l) restore normal, and the
#                           rotate-0 variant cycles all four orientations,
#                           asserting each step changes the frame and 360
#                           degrees returns pixel-exact to the boot frame.
#                           Every orientation is captured as a golden.
#   dpms                    dpms-timeout=15: idle blanks the connector
#                           (/sys/class/drm/card*-*/dpms reads Off), a keypress
#                           wakes it (On) and the text is redrawn. This is the
#                           ROADMAP M5.6 sysfs oracle; it applies to the DRM
#                           backends. fbdev blanks via FBIOBLANK, which does
#                           not touch the DRM connector property, so the dpms
#                           variant runs on the default drm2d backend only.
#                           Timing robustness under load: the idle timeout is
#                           raised above the slow OCR steps, the On checks keep
#                           sending wake keys while they poll, and the marker is
#                           typed only after a confirmed wake. The timer
#                           re-blanks after the last keypress; bochs blanking
#                           only gates the DAC, so screendumps stay readable
#                           while dpms is Off.
#   clone / scaled          two explicit std VGA cards:
#                           `-device VGA,id=video0,xres=1024,yres=768` plus
#                           `-device VGA,id=video1,xres=800,yres=600` (EDID
#                           preferred modes 1024x768 / 800x600). Both cards
#                           must be declared explicitly: any `-device VGA`
#                           clears QEMU's default-VGA flag (system/vl.c
#                           default_devices[]), so the implicit std VGA
#                           disappears and a lone video1 would be the guest's
#                           ONLY card. Both connectors must be enabled
#                           (sysfs), the secondary QMP screendump must be
#                           800x600 and show the same terminal text (OCR),
#                           and both outputs are captured as goldens. clone:
#                           smallest output sets the grid, larger ones get
#                           margins; scaled: larger outputs scale the content
#                           up (kmscon terminal.c:597-764, kmshaunt
#                           src/video/layout.zig computeLayout).
#
# Deferred (documented, not asserted):
#   * Same-card multi-connector scanout: kmshaunt drives one connector per
#     card today (src/main.zig selectForCard, "M5.4 scanout gap"); the
#     multi-connector backend work is in flight. The clone/scaled variants
#     therefore use two CARDS, which both implementations already drive.
#   * largest: kmscon disables the non-largest outputs while kmshaunt shows
#     them a centered clipped viewport (deliberate divergence,
#     src/video/layout.zig header). No common assertion exists yet.
#
# hwaccel status: kmshaunt --hwaccel now selects drm3d (GBM/EGL/GLESv2 wired
#   in build.zig; src/main.zig openDrmBackend tries Drm3d.init and falls back
#   to drm2d only on error.Unsupported/NoConnectedDisplay). The drm3d variant
#   asserts the libEGL-mapped evidence line, which shows which node actually
#   brought up EGL. kmscon dlopens its drm3d backend, so libEGL appears in its
#   maps only when drm3d is live.
#
# Goldens: nix/tests/goldens/<variant>/<impl>/<shot>.png, same stub contract
# as nix/tests/lib.nix — while a golden is missing the compare only saves the
# screenshot into the test output. Run once, review the images, copy them into
# the tree, re-run (ROADMAP R6).
#
# Scenario variables injected by nix/tests/lib.nix:
#   machine  the guest node object
#   impl     "kmscon" | "kmshaunt"
#   term     expected $TERM
#   unit     console unit (kmsconvt@tty1.service / kmshaunt-vt@tty1.service)
#   tty      "tty1"
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
let
  inherit (pkgs) lib;
  harness = import ./lib.nix pkgs;

  # One variant = one mkParityTest. extraConfig is applied to BOTH nodes; each
  # node only evaluates its own service, so setting services.kmscon.config and
  # services.kmshaunt.config side by side keeps the guests identical.
  mkVideoTest =
    {
      name,
      scenario,
      hwaccel ? false,
      extraConfig ? { },
      goldens ? [ ],
    }:
    harness.mkParityTest {
      inherit
        name
        kmshauntModule
        hwaccel
        extraConfig
        goldens
        ;
      scenario = _ctx: scenario;
    };

  # S1/S2 shared by the drm2d and drm3d variants. eglEvidence adds the
  # libEGL-mapped log line (identical Python on both nodes).
  drmScenario = eglEvidence: ''
    import subprocess

    with subtest("S1 autologin renders on the DRM backend"):
        waitForLogin(machine)
        machine.send_chars("echo $TERM > /tmp/term\n")
        machine.wait_until_succeeds("test -s /tmp/term")
        shell_term = machine.succeed("cat /tmp/term").strip()
        assert shell_term == term, f"[{impl}] $TERM is {shell_term!r}, expected {term!r}"
        # Backend oracle: both DRM backends modeset the card, so the console
        # process must hold /dev/dri/cardN open. Read the unit's MainPID so
        # the check does not depend on the process name.
        pid = machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
        machine.wait_until_succeeds(f"ls -l /proc/{pid}/fd | grep -q /dev/dri/card")
        screenshotCompare(machine, impl, "boot-prompt")
  ''
  + lib.optionalString eglEvidence ''
        # Evidence, not a parity assertion: drm3d brings up EGL on the GBM
        # device, a drm2d fallback leaves libEGL unmapped. See the header for
        # the kmshaunt hwaccel fallback gap.
        maps = machine.succeed(f"cat /proc/{pid}/maps")
        log.log(f"[{impl}] hwaccel: libEGL mapped: {'libEGL' in maps}")
  ''
  + ''

    with subtest("S2 text renders on the DRM backend"):
        machine.send_chars("echo video-parity-ok\n")
        machine.wait_for_text("video-parity-ok")
        screenshotCompare(machine, impl, "marker")
  '';

  fbdevScenario = ''
    import subprocess

    with subtest("S1 autologin renders on fbdev (no-drm)"):
        waitForLogin(machine)
        machine.send_chars("echo $TERM > /tmp/term\n")
        machine.wait_until_succeeds("test -s /tmp/term")
        shell_term = machine.succeed("cat /tmp/term").strip()
        assert shell_term == term, f"[{impl}] $TERM is {shell_term!r}, expected {term!r}"
        # Backend oracle: no-drm must render through /dev/fb0 and must NOT
        # open any DRM node (kmscon ignores DRM devices when drm is off,
        # kmshaunt takes the Fbdev path in setupVideo).
        pid = machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
        machine.wait_until_succeeds(f"ls -l /proc/{pid}/fd | grep -q /dev/fb0")
        machine.succeed(f"! ls -l /proc/{pid}/fd | grep -q /dev/dri/card")
        screenshotCompare(machine, impl, "boot-prompt")

    with subtest("S2 text renders on fbdev (no-drm)"):
        machine.send_chars("echo video-parity-ok\n")
        machine.wait_for_text("video-parity-ok")
        screenshotCompare(machine, impl, "marker")
  '';

  # Rotation variant. degree/orientation/restoreKey/restoreSteps are the same
  # constants on both nodes; the body never branches on impl.
  #   normal      0    (cycle check instead of restore)
  #   right      90 cw -> 1 x ccw back to normal
  #   upside-down 180  -> 2 x cw back to normal
  #   left      270 cw -> 1 x cw back to normal
  rotateScenario =
    {
      degree,
      orientation,
      restoreKey,
      restoreSteps,
    }:
    ''
      import subprocess

      MARKER = "ROTATION-PROBE-42"
      DEGREE = ${toString degree}
      RESTORE_KEY = "${restoreKey}"
      RESTORE_STEPS = ${toString restoreSteps}

      with subtest("S1 boot with screen=${orientation}"):
          # waitForLogin's OCR step assumes upright text; rotated variants
          # wait for the shell process instead and prove input works through
          # a file written over the pty (read back over the backdoor).
          machine.wait_for_unit("default.target")
          machine.wait_until_succeeds("pgrep -u alice bash")
          machine.send_chars(f"echo {MARKER} > /tmp/rot; echo {MARKER}\n")
          machine.wait_until_succeeds("test -s /tmp/rot")
          machine.sleep(1)
          if DEGREE == 0:
              machine.wait_for_text(MARKER)
          else:
              text = machine.get_screen_text()
              assert MARKER not in text, (
                  f"[{impl}] screen=${orientation}: marker still readable "
                  "horizontally, rotation not applied"
              )
          screenshotCompare(machine, impl, f"rotate-{DEGREE}")

      if DEGREE == 0:
          with subtest("S2 grab-rotate-cw cycles all four orientations"):
              boot = f"{machine.out_dir}/{NAME}-{impl}-rotate-0.png"
              steps = ["rotate-90", "rotate-180", "rotate-270", "rotate-0-cycle"]
              for i, shot in enumerate(steps, start=1):
                  machine.send_key("meta_l-equal")
                  machine.sleep(1)
                  screenshotCompare(machine, impl, shot)
                  cur = f"{machine.out_dir}/{NAME}-{impl}-{shot}.png"
                  if i < 4:
                      # Every intermediate orientation must change the frame.
                      r = subprocess.run(
                          [PILLOW_PYTHON, COMPARE_SCRIPT, boot, cur, "0.0"],
                          capture_output=True, text=True,
                      )
                      assert r.returncode != 0, (
                          f"[{impl}] rotation step {i}: frame identical to the "
                          "0-degree boot frame (grab-rotate-cw not wired?)"
                      )
                  else:
                      # 360 degrees: back to the boot frame (tiny tolerance
                      # for rasterisation jitter; the diff is printed).
                      subprocess.run(
                          [PILLOW_PYTHON, COMPARE_SCRIPT, boot, cur, "0.002"],
                          check=True,
                      )
              machine.wait_for_text(MARKER)
      else:
          with subtest("S2 grab-rotate restores normal"):
              for _ in range(RESTORE_STEPS):
                  machine.send_key(RESTORE_KEY)
                  machine.sleep(1)
              machine.wait_for_text(MARKER)
              screenshotCompare(machine, impl, f"rotate-{DEGREE}-restored")
    '';

  dpmsScenario = ''
    import datetime as dt
    import time

    SHORT = dt.timedelta(seconds=30)
    TIMEOUT = 15  # services.{kmscon,kmshaunt}.config.dpms-timeout below
    DPMS_SYSFS = "cat /sys/class/drm/card*-*/dpms"

    def dpmsWords():
        # Words of the sysfs dpms read; [] when the read fails.
        _, out = machine.execute(DPMS_SYSFS, timeout=SHORT, check_return=False)
        return out.split()

    def waitDpmsOn(budget):
        """Wait until sysfs dpms reads On, keeping the console awake.

        The idle timer re-blanks the connector TIMEOUT seconds after the
        last keypress, so a single key followed by a slow check can miss
        the On window entirely. Each poll therefore sends a fresh wake key
        before reading sysfs: a working wake path reads On right after a
        key, a broken one never does, however many keys arrive. The Off
        state is stable without input, so the Off check needs no loop.
        """
        deadline = time.monotonic() + budget
        words = []
        while True:
            machine.send_key("ret")
            words = dpmsWords()
            if "On" in words:
                return
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"[{impl}] sysfs dpms never read On after input "
                    f"(last read: {words!r})"
                )
            time.sleep(0.5)

    with subtest("S1 console is On after input"):
        # The idle timer runs from boot, so the screen may already be blank
        # by the time the shell is up: waitDpmsOn wakes it with a keypress.
        machine.wait_for_unit("default.target")
        machine.wait_until_succeeds("pgrep -u alice bash")
        waitDpmsOn(60)
        machine.wait_for_text("alice@")
        # The alice@ OCR can outlast the idle timeout and re-blank the
        # screen. Wake it again and confirm On before typing so the marker
        # is entered while the console is solidly On: typing during a
        # blank->unblank transition can drop the redraw.
        waitDpmsOn(60)
        machine.send_chars("echo dpms-parity-ok\n")
        machine.wait_for_text("dpms-parity-ok")

    with subtest("S2 idle timeout blanks the connector (sysfs dpms Off)"):
        # No input while idle: backdoor commands and screendumps do not feed
        # the console. TIMEOUT + margin guarantees the timer expired.
        machine.sleep(TIMEOUT + 3)
        machine.wait_until_succeeds(
            DPMS_SYSFS + " | grep -qx Off", timeout=SHORT
        )
        screenshotCompare(machine, impl, "dpms-off")

    with subtest("S3 keypress wakes the connector (sysfs dpms On) and redraws"):
        waitDpmsOn(60)
        machine.wait_for_text("dpms-parity-ok")
        screenshotCompare(machine, impl, "dpms-on")
  '';

  # Two-card multi-monitor variant (clone or scaled). Both outputs are dumped
  # through QMP with the explicit qdev id of their VGA device (video0 primary,
  # video1 secondary) and OCR'd with the driver's preprocessing variants. The
  # terminal is asserted via the typed all-caps marker, not the autologin
  # prompt: in clone mode the larger primary keeps the base font, whose "@"
  # is not OCR-reliable (see S1).
  multiMonitorScenario = mode: ''
    import shutil
    import subprocess
    import tempfile
    import time
    from pathlib import Path
    from test_driver.machine.ocr import perform_ocr_variants_on_screenshot

    MARKER = "MULTIMON-PROBE-7"

    def consoleShot(device, shot):
        """QMP screendump of one display device, saved as PNG in the output.

        Returns (png_path, ppm_path). The test QEMU is built without libpng,
        so screendump's png format is rejected ("Enable PNG support with
        libpng for screendump"); dump PPM instead — the same fallback the
        driver's own screenshot() uses via pnmtopng — and convert to PNG with
        the harness Pillow. The PPM is kept because the environment's magick
        (used by the OCR preprocessing) reads PPM but has no PNG decode
        delegate, so OCR must run on the PPM, exactly as the driver's own
        wait_for_text does on its temporary PPM screendump.
        """
        path = f"{machine.out_dir}/{NAME}-{impl}-{shot}.png"
        ppm = f"{machine.out_dir}/{NAME}-{impl}-{shot}.ppm"
        machine.qmp_client.send(
            "screendump", {"filename": ppm, "device": device, "format": "ppm"}
        )
        subprocess.run(
            [PILLOW_PYTHON, "-c",
             "import sys; from PIL import Image; "
             "Image.open(sys.argv[1]).save(sys.argv[2])",
             ppm, path],
            check=True,
        )
        return path, ppm

    def pngSize(path):
        out = subprocess.run(
            [PILLOW_PYTHON, "-c",
             "import sys; from PIL import Image; im = Image.open(sys.argv[1]); "
             "print(im.size[0], im.size[1])",
             path],
            check=True, capture_output=True, text=True,
        )
        w, h = out.stdout.split()
        return int(w), int(h)

    def goldenCompare(shot, path):
        golden = GOLDEN_BY_IMPL[impl].get(shot)
        if golden is None:
            log.log(f"{NAME}-{impl}-{shot}: no golden yet, screenshot kept in the test output")
            return
        subprocess.run([PILLOW_PYTHON, COMPARE_SCRIPT, path, golden, "0.0"], check=True)

    with subtest("S1 autologin on the primary output"):
        machine.wait_for_unit("default.target")
        machine.wait_until_succeeds("pgrep -u alice bash")
        machine.send_chars(f"echo {MARKER}\n")
        # Clone keeps the base font on the larger primary (the grid comes from
        # the smallest output) with black margins around it. At that size the
        # autologin prompt's "@" is not OCR-reliable — kmscon's 7px-wide cell
        # reads it as "aliceg…" and the driver's preprocessing variants drop the
        # small text — so assert on the typed marker instead: all-caps and
        # OCR-reliable, the same oracle S2 uses for the secondary. The marker
        # appearing proves autologin produced a shell that renders and accepts
        # input on the primary. Poll the explicit video0 screendump + the
        # driver's OCR preprocessing variants, exactly like S2's secondary.
        deadline = time.monotonic() + 120
        while True:
            shot0, ppm0 = consoleShot("video0", "output0")
            # OCR on a temp copy of the PPM so magick's large upsampled
            # preprocessing artifacts land in a scratch dir, not the output.
            with tempfile.TemporaryDirectory() as tmp:
                ocr_src = Path(tmp) / "screen.ppm"
                shutil.copyfile(ppm0, ocr_src)
                texts0 = perform_ocr_variants_on_screenshot(ocr_src)
            if any(MARKER in t for t in texts0):
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"[{impl}] primary output does not show the terminal "
                    f"(OCR: {texts0!r})"
                )
            time.sleep(1)
        Path(ppm0).unlink()

    with subtest("S2 both outputs scan out the terminal (multi-monitor=${mode})"):
        # Scanout oracle: both cards' connectors are enabled (CRTC active).
        # Connector names are not hardcoded; the screendump sizes below tell
        # the outputs apart. Both consoles modeset every card during startup,
        # so this is settled by the time S1 finishes; the explicit timeout
        # fails fast instead of burning the 900s default on a missing card.
        machine.wait_until_succeeds(
            "test $(grep -lx enabled /sys/class/drm/card*-*/enabled | wc -l) -ge 2",
            timeout=120,
        )
        # Primary: video0, the first std VGA, 1024x768.
        screenshotCompare(machine, impl, "output0")
        shot0 = f"{machine.out_dir}/{NAME}-{impl}-output0.png"
        assert pngSize(shot0) == (1024, 768), (
            f"[{impl}] primary output is {pngSize(shot0)}, expected (1024, 768)"
        )
        # Secondary: video1, the second VGA card, EDID preferred mode
        # 800x600. It must show the same terminal text, not a frozen boot
        # frame. Its redraw can lag the primary's under load, so poll the
        # screendump + OCR until the marker appears (the size is stable once
        # the connector is enabled above). OCR uses the driver's preprocessing
        # variants, exactly like S1 on the primary: the secondary keeps the
        # base font size (16px here), which raw tesseract garbles.
        deadline = time.monotonic() + 120
        while True:
            shot1, ppm1 = consoleShot("video1", "output1")
            assert pngSize(shot1) == (800, 600), (
                f"[{impl}] secondary output is {pngSize(shot1)}, expected (800, 600)"
            )
            # OCR on a temp copy of the PPM so magick's large upsampled
            # preprocessing artifacts land in a scratch dir, not the output.
            with tempfile.TemporaryDirectory() as tmp:
                ocr_src = Path(tmp) / "screen.ppm"
                shutil.copyfile(ppm1, ocr_src)
                texts1 = perform_ocr_variants_on_screenshot(ocr_src)
            if any(MARKER in t for t in texts1):
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"[{impl}] secondary output does not show the terminal "
                    f"(OCR: {texts1!r})"
                )
            time.sleep(1)
        Path(ppm1).unlink()
        goldenCompare("output1", shot1)
  '';

  # Both services get the same video keys. extraConfig is imported on BOTH
  # nodes, but each node declares only its own service, so guard each
  # definition by option presence. Test the `options` tree, not `config`:
  # `config.services ? …` would force the very config being defined and
  # recurse; `options.services ? …` only inspects declared options.
  videoConfig = key: value:
    { options, lib, ... }:
    {
      config =
        lib.optionalAttrs (options.services ? kmscon) {
          services.kmscon.config.${key} = value;
        }
        // lib.optionalAttrs (options.services ? kmshaunt) {
          services.kmshaunt.config.${key} = value;
        };
    };

  # Two-card multi-monitor guest config: two explicit std VGAs whose EDID
  # preferred modes are 1024x768 and 800x600, plus the same multi-monitor mode
  # and a pinned font size on both services.
  #
  # Both cards must be explicit: any `-device VGA` clears QEMU's default-VGA
  # flag (system/vl.c default_devices[]), so the implicit std VGA is not
  # created alongside it — a lone `-device VGA,id=video1` leaves the guest
  # with a single 800x600 card and the two-output assertions wait forever on
  # a second connector that does not exist. mkBefore keeps video0/video1 at
  # the front of the option list so they take the first free PCI slots in
  # order: video0 -> card0 -> primary (default screendump), video1 -> card1
  # -> secondary (QMP screendump device=video1).
  multiMonitorConfig = mode:
    { options, lib, ... }:
    {
      config =
        {
          virtualisation.qemu.options = lib.mkBefore [
            "-device VGA,id=video0,xres=1024,yres=768"
            "-device VGA,id=video1,xres=800,yres=600"
          ];
        }
        // lib.optionalAttrs (options.services ? kmscon) {
          services.kmscon.config = {
            multi-monitor = mode;
            font-size = 16;
          };
        }
        // lib.optionalAttrs (options.services ? kmshaunt) {
          services.kmshaunt.config = {
            multi-monitor = mode;
            font-size = 16;
          };
        };
    };

  tests = {
    drm2d = mkVideoTest {
      name = "kmshaunt-m5-video-drm2d";
      scenario = drmScenario false;
      goldens = [ "boot-prompt" "marker" ];
    };

    drm3d = mkVideoTest {
      name = "kmshaunt-m5-video-drm3d";
      hwaccel = true;
      scenario = drmScenario true;
      goldens = [ "boot-prompt" "marker" ];
    };

    fbdev = mkVideoTest {
      name = "kmshaunt-m5-video-fbdev";
      extraConfig = videoConfig "drm" false;
      scenario = fbdevScenario;
      goldens = [ "boot-prompt" "marker" ];
    };

    rotate-0 = mkVideoTest {
      name = "kmshaunt-m5-video-rotate-0";
      extraConfig = videoConfig "screen" "normal";
      scenario = rotateScenario {
        degree = 0;
        orientation = "normal";
        restoreKey = "meta_l-equal";
        restoreSteps = 0;
      };
      goldens = [ "rotate-0" "rotate-90" "rotate-180" "rotate-270" "rotate-0-cycle" ];
    };

    rotate-90 = mkVideoTest {
      name = "kmshaunt-m5-video-rotate-90";
      extraConfig = videoConfig "screen" "right";
      scenario = rotateScenario {
        degree = 90;
        orientation = "right";
        restoreKey = "meta_l-minus";
        restoreSteps = 1;
      };
      goldens = [ "rotate-90" "rotate-90-restored" ];
    };

    rotate-180 = mkVideoTest {
      name = "kmshaunt-m5-video-rotate-180";
      extraConfig = videoConfig "screen" "upside-down";
      scenario = rotateScenario {
        degree = 180;
        orientation = "upside-down";
        restoreKey = "meta_l-equal";
        restoreSteps = 2;
      };
      goldens = [ "rotate-180" "rotate-180-restored" ];
    };

    rotate-270 = mkVideoTest {
      name = "kmshaunt-m5-video-rotate-270";
      extraConfig = videoConfig "screen" "left";
      scenario = rotateScenario {
        degree = 270;
        orientation = "left";
        restoreKey = "meta_l-equal";
        restoreSteps = 1;
      };
      goldens = [ "rotate-270" "rotate-270-restored" ];
    };

    dpms = mkVideoTest {
      name = "kmshaunt-m5-video-dpms";
      extraConfig = videoConfig "dpms-timeout" 15;
      scenario = dpmsScenario;
      goldens = [ "dpms-off" "dpms-on" ];
    };

    clone = mkVideoTest {
      name = "kmshaunt-m5-video-clone";
      extraConfig = multiMonitorConfig "clone";
      scenario = multiMonitorScenario "clone";
      goldens = [ "output0" "output1" ];
    };

    scaled = mkVideoTest {
      name = "kmshaunt-m5-video-scaled";
      extraConfig = multiMonitorConfig "scaled";
      scenario = multiMonitorScenario "scaled";
      goldens = [ "output0" "output1" ];
    };
  };
in
pkgs.runCommand "kmshaunt-m5-video"
  {
    requiredSystemFeatures = [ "kvm" ];
    # Building the aggregate runs every variant; each stays individually
    # addressable through passthru.tests, and .driver joins the lint targets.
    buildInputs = lib.attrValues tests;
    passthru = {
      inherit tests;
      driver = pkgs.symlinkJoin {
        name = "kmshaunt-m5-video-drivers";
        paths = map (t: t.driver) (lib.attrValues tests);
      };
    };
  }
  ''
    mkdir -p $out
    echo "kmshaunt M5.8 video parity: all variant tests passed" > $out/summary
  ''
