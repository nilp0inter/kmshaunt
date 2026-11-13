# Interactive kmshaunt test VM: the proven M1.8 console setup plus btop, lsd
# and ttytoys (terminal-toys) for hands-on testing over VNC.
#
# The kmshaunt package is not set here: nix/module.nix has no usable default
# (pkgs.kmshaunt is not in nixpkgs). The flake wrapper
# (modules/flake/test-vm.nix) supplies it and imports qemu-vm.nix, so
#
#   nix build .#nixosConfigurations.test-vm.config.system.build.vm
#   QEMU_OPTS="-display none -vnc :1" ./result/bin/run-kmshaunt-test-vm
#
# yields a VNC-capable VM. Console/graphics settings mirror the M1.8 parity
# guest (nix/tests/lib.nix deterministicVm): hardware.graphics + std VGA
# (bochs-drm), fontconfig + JetBrains Mono, 1024x768, autologin on tty1.
{
  pkgs,
  ttytoys,
  ...
}:
{
  imports = [ ./module.nix ];

  services.kmshaunt = {
    enable = true;
    config = {
      font-name = "JetBrains Mono";
      term = "xterm-ghostty";
      blink = false;
    };
  };

  hardware.graphics.enable = true;
  fonts.fontconfig.enable = true;
  fonts.packages = [ pkgs.jetbrains-mono ];

  virtualisation.resolution = {
    x = 1024;
    y = 768;
  };
  virtualisation.memorySize = 4096;
  virtualisation.cores = 4;
  # /dev/kvm is required; fail early instead of crawling under TCG.
  virtualisation.qemu.forceAccel = true;
  # std VGA = bochs-drm, the DRM device the M1.8 test verified.
  virtualisation.qemu.options = [ "-vga std" ];

  services.getty.autologinUser = "testuser";
  users.users.testuser = {
    isNormalUser = true;
    description = "kmshaunt test user";
    uid = 1000;
    extraGroups = [
      "wheel"
      "video"
      "input"
    ];
    password = "test";
  };
  users.users.root.password = "root";
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    pkgs.btop
    pkgs.lsd
    ttytoys
    pkgs.git
    pkgs.vim
    pkgs.htop
  ];

  # kmshaunt owns the console; no X.
  services.xserver.enable = false;

  # Convenience: ssh -p 2222 testuser@localhost (password: test).
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  networking.firewall.allowedTCPPorts = [ 22 ];
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 2222;
      guest.port = 22;
    }
  ];

  networking.hostName = "kmshaunt-test";
  system.stateVersion = "26.05";
}
