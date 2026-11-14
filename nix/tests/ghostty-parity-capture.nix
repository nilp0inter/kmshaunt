# Ghostty-parity frame capture: boots TWO otherwise-identical NixOS VMs, one
# running kmshaunt on the DRM console and one running ghostty fullscreen under
# cage (Wayland kiosk), cats every fixtures/ghostty-parity frame into each, and
# saves a QMP screendump per (node, frame). The screenshots are the evidence for
# the autoresearch pixel-diff loop; this test only captures, it does not compare.
#
# Built directly via --expr (like the m8-perf justfile recipe), NOT registered in
# the auto-generated flake.nix:
#
#   nix build --impure --expr '... import ./nix/tests/ghostty-parity-capture.nix {
#     inherit pkgs comicCode framesDir; kmshauntModule = ...; }'
#
# Identical-config contract: both nodes share `sharedBase` (resolution, graphics
# device, the SAME font set, autologin user, empty shell prompt). The only
# intended difference is the terminal implementation. Font/size mirror the user's
# nixos-config ghostty aspect (ComicCodeLigatures Nerd Font, 14px). ghostty also
# gets the user's cell adjustments; kmshaunt has no equivalent knobs yet, so that
# delta is deliberately left visible for inspection.
{
  pkgs,
  kmshauntModule,
  comicCode,
  framesDir,
}:
let
  inherit (pkgs) lib;

  resolution = {
    x = 1024;
    y = 768;
  };

  # Mirrors nixos-config: stylix monospace + ghostty font-family* = this family.
  fontName = "ComicCodeLigatures Nerd Font";
  fontSize = 14;

  # Identical font set on BOTH nodes. comic-code is the primary monospace;
  # Noto Color Emoji matches stylix emoji; CJK + Noto give fontconfig fallback
  # for the wide/bidi/shaping frames so neither side shows tofu.
  fontPackages = [
    comicCode
    pkgs.noto-fonts-color-emoji
    pkgs.noto-fonts-cjk-sans
    pkgs.noto-fonts
  ];

  frameNames =
    let
      entries = builtins.readDir framesDir;
    in
    lib.sort builtins.lessThan (
      lib.filter (n: lib.hasSuffix ".bin" n) (builtins.attrNames entries)
    );

  userAccount = {
    users.users.alice = {
      isNormalUser = true;
      description = "parity capture user";
      password = "foobar";
      uid = 1000;
      extraGroups = [
        "wheel"
        "video"
        "input"
      ];
    };
  };

  sharedBase =
    { ... }:
    {
      imports = [ userAccount ];

      hardware.graphics.enable = true;
      fonts.fontconfig.enable = true;
      fonts.packages = fontPackages;

      virtualisation.resolution = resolution;
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      # /dev/kvm required; fail fast instead of crawling under TCG.
      virtualisation.qemu.forceAccel = lib.mkForce true;
      # virtio-vga: display + DRM render node. cage/wlroots needs a render node
      # (bochs-drm has none); kmshaunt drm2d/drm3d both work on virtio too.
      virtualisation.qemu.options = [ "-vga virtio" ];

      services.getty.autologinUser = "alice";

      # Empty prompt on BOTH nodes so the shell does not draw a PS1 over the
      # frame after `cat` returns. The frame's RIS clears the typed command echo.
      programs.bash.promptInit = lib.mkForce ''
        PS1=""
        PS2=""
      '';

      environment.systemPackages = [ pkgs.bashInteractive ];
      environment.etc."parity-frames".source = framesDir;

      networking.hostName = "parity-capture";
      system.stateVersion = "26.05";
    };

  kmshauntNode =
    { ... }:
    {
      imports = [
        sharedBase
        kmshauntModule
      ];

      services.kmshaunt = {
        enable = true;
        fonts = fontPackages;
        config = {
          font-name = fontName;
          font-size = fontSize;
          blink = false;
          term = "xterm-ghostty";
          # Same user settings as the ghostty node below (ghostty-compatible
          # knobs now exist in kmshaunt); parity comes from identical config.
          adjust-cell-width = "-5%";
          adjust-cell-height = "-15%";
          adjust-font-baseline = "+18%";
        };
      };
    };

  # ghostty config = the user's nixos-config desktop/ghostty aspect, plus
  # determinism-only additions (cursor blink off, no shell integration, explicit
  # bash). Served via XDG_CONFIG_HOME so no home-manager is needed.
  ghosttyConfig = ''
    font-family = ${fontName}
    font-family-bold = ${fontName}
    font-family-italic = ${fontName}
    font-family-bold-italic = ${fontName}
    font-size = ${toString fontSize}
    # Match kmshaunt's CURRENT default colors (libtsm legacy palette) so the
    # comparison starts color-aligned. kmshaunt itself is left untouched.
    background = #000000
    foreground = #e5e5e5
    palette = 0=#000000
    palette = 1=#cd0000
    palette = 2=#00cd00
    palette = 3=#cdcd00
    palette = 4=#0000ee
    palette = 5=#cd00cd
    palette = 6=#00cdcd
    palette = 7=#e5e5e5
    palette = 8=#7f7f7f
    palette = 9=#ff0000
    palette = 10=#00ff00
    palette = 11=#ffff00
    palette = 12=#5c5cff
    palette = 13=#ff00ff
    palette = 14=#00ffff
    palette = 15=#ffffff
    fullscreen = true
    window-decoration = false
    mouse-scroll-multiplier = 1.0
    adjust-cell-width = -5%
    adjust-cell-height = -15%
    adjust-font-baseline = +18%
    confirm-close-surface = false
    cursor-style-blink = false
    shell-integration = none
    command = ${pkgs.bashInteractive}/bin/bash
  '';

  # Autologin on tty1 runs this as alice's login shell: getty/login create the
  # logind session on seat0 (which wlroots needs for DRM master), then exec cage
  # with ghostty fullscreen. ghostty runs bash inside, which is where the frames
  # are catted.
  cageSession =
    (pkgs.writeShellScriptBin "cage-ghostty-session" ''
      export XDG_CONFIG_HOME=/etc/ghostty-xdg
      export XDG_RUNTIME_DIR=/run/user/1000
      exec ${lib.getExe pkgs.cage} -- ${lib.getExe pkgs.ghostty}
    '').overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          shellPath = "/bin/cage-ghostty-session";
        };
      });

  ghosttyNode =
    { lib, ... }:
    {
      imports = [ sharedBase ];

      environment.systemPackages = [
        pkgs.cage
        pkgs.ghostty
        cageSession
      ];
      environment.etc."ghostty-xdg/ghostty/config".text = ghosttyConfig;

      users.users.alice.shell = cageSession;
      environment.shells = [ cageSession ];
    };
in
pkgs.testers.runNixOSTest {
  name = "ghostty-parity-capture";
  enableOCR = false;
  globalTimeout = 60 * 60;

  nodes = {
    kmshaunt = kmshauntNode;
    ghostty = ghosttyNode;
  };

  testScript = ''
    FRAMES = ${lib.strings.toJSON frameNames};
    NODES = ["kmshaunt", "ghostty"];

    start_all()

    # Wait until each terminal has an interactive bash on the VT.
    for node in NODES:
        m = globals()[node]
        m.wait_for_unit("multi-user.target")
        m.wait_until_succeeds("pgrep -u alice bash", timeout=240)
        m.sleep(3)

    # Feed every frame to both nodes and capture. Screenshot names are
    # <node>-<frame-stem>.png so the pairs line up for the diff.
    for frame in FRAMES:
        stem = frame[:-4]
        for node in NODES:
            m = globals()[node]
            m.send_chars("cat /etc/parity-frames/" + frame + "\n")
            m.sleep(2)
            m.screenshot(f"{node}-{stem}")
  '';
}