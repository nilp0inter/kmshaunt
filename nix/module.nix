# services.kmshaunt — NixOS module (ROADMAP M7.3).
#
# Mirrors nixpkgs' services.kmscon module, with the three kmshaunt-specific
# differences called out where they occur:
#
#   * kmshaunt's config file is <configdir>/kmshaunt.conf and its default
#     $TERM is xterm-ghostty, not kmscon (ROADMAP D5/D6), so the module also
#     installs ghostty's terminfo entry.
#   * getty@.service is NOT suppressed: the console unit declares
#     OnFailure=getty@%i.service, and that fallback (plus the T4 S3 scenario)
#     needs the template to stay loadable. Only its autovt@ alias moves.
#   * the multi-seat daemon (`kmshaunt.service`) exists as the M6.2 hook.
#
# The module is standalone: it is importable as a plain file
# (`import ./nix/module.nix`, which is what the T4 harness does) and the flake
# re-exports it as `nixosModules.kmshaunt`, where the wrapper supplies the
# flake's own build as the package default. `pkgs.kmshaunt` is not in nixpkgs,
# so `services.kmshaunt.package` must be set (the flake does that for you).
{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.kmshaunt;

  gettyCfg = config.services.getty;

  # kmshaunt discovers <configdir>/kmshaunt.conf and <configdir>/<seat>.seat.conf
  # (kmscon precedence, D5), so the unit gets the *directory*. writeTextFile
  # with a destination yields exactly that: a store path holding the file.
  configDir = pkgs.writeTextFile {
    name = "kmshaunt-config";
    destination = "/kmshaunt.conf";
    text =
      let
        # kmshaunt's file syntax: a bare key for true, `no-<key>` for false,
        # `key=value` otherwise (conf.c, docs/reference/kmscon-options.md §3).
        mkKeyValue =
          k: v: if lib.isBool v then (lib.optionalString (!v) "no-") + k else "${k}=${toString v}";
      in
      lib.generators.toKeyValue { inherit mkKeyValue; } (lib.filterAttrs (_: v: v != null) cfg.config);
  };

  # The VT process runs the login program itself (--login -- <argv>), so the
  # autologin knobs of the agetty module are honoured here: kmscon does the
  # same, and both implementations must behave identically in the T4 harness.
  baseLoginOptions = "-p";

  loginCmd =
    enableAutologin:
    "${gettyCfg.loginProgram} ${baseLoginOptions}${
      lib.optionalString enableAutologin " -f -- ${lib.escapeShellArg gettyCfg.autologinUser}"
    }";

  loginScript = pkgs.writers.writeBash "kmshaunt-login" (
    lib.optionalString (gettyCfg.autologinUser != null && gettyCfg.autologinOnce) ''
      kms_tty=
      active_tty_file=/sys/class/tty/tty0/active
      if [ -f "$active_tty_file" ]; then
        read -r kms_tty < "$active_tty_file"
      fi

      autologged="/run/kmshaunt.autologged"
      if [ "$kms_tty" = tty1 ] && [ ! -f "$autologged" ]; then
        touch "$autologged"
        exec ${loginCmd true}
      fi
    ''
    + "exec ${loginCmd (gettyCfg.autologinUser != null && !gettyCfg.autologinOnce)}"
  );

  # ROADMAP D6: kmshaunt's default $TERM is xterm-ghostty, so the terminfo
  # entry has to be on the system or every curses application in the console
  # session fails to initialise. ghostty installs share/terminfo into a
  # separate `terminfo` output; NixOS' profileRelativeSessionVariables adds
  # /run/current-system/sw/share/terminfo to TERMINFO_DIRS, so putting that
  # output in environment.systemPackages is the supported mechanism (the
  # ghostty package documents exactly this for remote machines).
  terminfoPackage = pkgs.ghostty.terminfo;

  kmshauntVtExec =
    args:
    builtins.concatStringsSep " " (
      [ (lib.getExe cfg.package) "--configdir" (toString configDir) ]
      ++ args
      ++ lib.optional (cfg.extraOptions != "") cfg.extraOptions
      ++ [
        "--"
        (toString loginScript)
      ]
    );
in
{
  options.services.kmshaunt = {
    enable = mkEnableOption ''
      kmshaunt as the system console.

      kmshaunt is a userspace terminal emulator on top of the kernel's KMS/DRM
      interface (a kmscon-compatible replacement for the in-kernel VT and for
      `autovt`). It takes over tty1 at boot, answers `autovt@` on VT switches,
      and hands the VT back to `getty@` if its own unit dies.
    '';

    package = mkPackageOption pkgs "kmshaunt" {
      extraDescription = ''
        kmshaunt is not in nixpkgs, so this has to be set explicitly unless the
        module is imported through the flake's `nixosModules.kmshaunt`, which
        defaults it to the flake's own build
      '';
    };

    useXkbConfig = mkEnableOption ''
      copying the `services.xserver.xkb` keyboard settings into kmshaunt's
      configuration.

      If enabled, the layout, model, variant and options configured under
      `services.xserver.xkb` are injected into the kmshaunt config file as
      defaults, so an override in {option}`services.kmshaunt.config` still wins
    '';

    config = mkOption {
      description = ''
        Configuration for kmshaunt, written to `kmshaunt.conf` in the
        configuration directory handed to the console unit.

        Keys and values are kmscon 10.1.0 compatible (ROADMAP D5); see
        {file}`docs/reference/kmscon-options.md` for the full option surface.
        Booleans render as a bare key (`true`) or `no-<key>` (`false`).
      '';
      default = { };
      type = types.submodule {
        freeformType =
          with types;
          attrsOf (oneOf [
            bool
            int
            str
          ]);
        options = {
          hwaccel = mkEnableOption "hardware accelerated rendering";
          libseat = mkEnableOption "libseat for seat management, input and video devices";
        };
      };
    };

    extraOptions = mkOption {
      description = "Extra flags to pass to kmshaunt.";
      type = types.separatedString " ";
      default = "";
      example = "--term xterm-256color";
    };

    fonts = mkOption {
      description = ''
        Font packages to install for kmshaunt's FreeType backend.

        At least one monospace font is installed by default: without one
        fontconfig falls back to DejaVu Sans, which is not monospace.
      '';
      type = types.listOf types.package;
      default = [ pkgs.jetbrains-mono ];
      defaultText = lib.literalExpression "[ pkgs.jetbrains-mono ]";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = gettyCfg.loginOptions == null;
        message = "services.getty.loginOptions is not supported when services.kmshaunt is enabled.";
      }
      {
        assertion = (cfg.config ? font-name) -> config.fonts.fontconfig.enable;
        message = "services.kmshaunt.config.font-name requires fontconfig to be enabled (fonts.fontconfig.enable).";
      }
      {
        assertion = cfg.config.hwaccel -> config.hardware.graphics.enable;
        message = "Hardware acceleration for kmshaunt requires `hardware.graphics.enable` to be true.";
      }
    ];

    services.kmshaunt.config = mkIf cfg.useXkbConfig (
      lib.mapAttrs (_: lib.mkDefault) (
        lib.filterAttrs (_: v: v != "") {
          xkb-layout = config.services.xserver.xkb.layout;
          xkb-model = config.services.xserver.xkb.model;
          xkb-options = config.services.xserver.xkb.options;
          xkb-variant = config.services.xserver.xkb.variant;
        }
      )
    );

    environment.systemPackages = [
      cfg.package
      terminfoPackage
    ];

    fonts.packages = cfg.fonts;

    # One console per VT: logind starts autovt@ttyN on a VT switch, so the
    # template is aliased to autovt@.service. The getty module aliases its own
    # getty@.service to autovt@ as well; an alias may only point at one unit,
    # so the alias is taken away from getty@. The *unit* is left alone (unlike
    # the kmscon module, which suppresses it): OnFailure below needs it, and
    # `systemctl start getty@ttyN` must keep working.
    systemd.services."kmshaunt-vt@" = {
      description = "kmshaunt on %I";

      unitConfig = {
        # ROADMAP M1.7: if the console unit dies, hand the VT back to a getty
        # instead of leaving the user with a dead screen.
        OnFailure = "getty@%i.service";
        # Taking the VT back from a getty that is already running must work
        # too (e.g. after the fallback above, switch away and back).
        Conflicts = "getty@%i.service";
        IgnoreOnIsolate = true;
        ConditionPathExists = "/dev/tty0";
        After = [ "systemd-user-sessions.service" ];
        Before = [ "getty.target" ];
      };

      # Deliberately no systemd sandboxing (PrivateTmp, ProtectSystem,
      # SystemCallFilter, RestrictAddressFamilies, ...): this unit spawns
      # the user's login session as a child, and every restriction would
      # confine that session too (sudo, networking, /tmp, module loading).
      # Like getty@, the console unit stays unconfined; blast-radius
      # reduction lives in the daemon itself (ReleaseSafe build,
      # default-deny clipboard and private-OSC policy).
      serviceConfig = {
        # libseat needs a logind session with a seat, so in that mode the unit
        # goes through the PAM stack defined below. Without libseat kmshaunt
        # opens the devices itself and the child login does the authentication.
        User = mkIf (!cfg.config.libseat) "";
        PAMName = if cfg.config.libseat then "kmshaunt" else "";
        Environment = [ "XKB_CONFIG_ROOT=${config.services.xserver.xkb.dir}" ];
        ExecStart = [
          "" # override any inherited ExecStart with an empty one first
          (kmshauntVtExec [
            "--vt=%I"
            "--no-switchvt"
            "--login"
          ])
        ];
      };

      restartIfChanged = false;
      aliases = [ "autovt@.service" ];
    };

    # Clearing the alias on a disabled getty module would create an empty
    # getty@.service that shadows the upstream template, so it is conditional.
    systemd.services."getty@" = mkIf config.services.getty.enable {
      aliases = lib.mkForce [ ];
    };

    # tty1 is special: logind does not spawn autovt@tty1 on boot, it expects a
    # static pull-in through getty.target.
    systemd.targets.getty.wants = mkIf (!config.services.displayManager.enable) [
      "kmshaunt-vt@tty1.service"
    ];

    # Multi-seat daemon (ROADMAP M6.2). It runs without --vt and is meant to
    # watch logind seats and hand out one kmshaunt-vt@ per seat. The seat
    # monitoring is the M6.2 work: this module only defines the unit (so
    # `systemctl start kmshaunt` works for that work) and deliberately leaves
    # it out of any target's wants until M6.2 decides how it composes with the
    # tty1 console unit.
    systemd.services.kmshaunt = {
      description = "kmshaunt multi-seat console daemon";
      serviceConfig.ExecStart = "${lib.getExe cfg.package} --configdir ${toString configDir}";
      restartIfChanged = false;
    };

    # libseat mode registers a greeter session with logind (pam_systemd), which
    # is what gives libseat its seat. Same stack as the kmscon module.
    security.pam.services.kmshaunt = mkIf cfg.config.libseat {
      useDefaultRules = false;
      rules = {
        auth = utils.pam.autoOrderRules [
          {
            name = "permit";
            control = "required";
            modulePath = "${config.security.pam.package}/lib/security/pam_permit.so";
          }
        ];
        account = utils.pam.autoOrderRules [
          {
            name = "unix";
            control = "required";
            modulePath = config.security.pam.pam_unixModulePath;
          }
        ];
        session = utils.pam.autoOrderRules [
          {
            name = "env";
            control = "required";
            modulePath = "${config.security.pam.package}/lib/security/pam_env.so";
            settings = {
              conffile = "/etc/pam/environment";
              readenv = 0;
            };
          }
          {
            name = "unix";
            control = "required";
            modulePath = config.security.pam.pam_unixModulePath;
          }
          {
            name = "systemd";
            control = "optional";
            modulePath = "${config.systemd.package}/lib/security/pam_systemd.so";
            settings = {
              type = "tty";
              class = "greeter";
            };
          }
        ];
      };
    };
  };
}