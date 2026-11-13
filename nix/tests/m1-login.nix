# M1 exit scenarios (ROADMAP §5, M1) as a T4 parity test: one scenario body, run
# against services.kmscon and services.kmshaunt on identical guests.
#
# Once the flake's checks wiring (modules/) imports this file:
#
#   nix build .#checks.<system>.kmshaunt-m1-login.driver  # lint/type-check only
#   nix build .#checks.<system>.kmshaunt-m1-login         # boots both VMs
#
# services.kmshaunt comes from nix/module.nix, which M7.3 adds. The argument is
# a *lazy default*, so this file parses and evaluates to a function today:
#
#   nix-instantiate --parse nix/tests/m1-login.nix
#   nix eval --impure --expr 'builtins.isFunction (import ./nix/tests/m1-login.nix)'
#
# Only forcing the test (or passing a stub `kmshauntModule`) needs that module.
#
# Scenario variables injected by nix/tests/lib.nix:
#   machine  the guest node object
#   impl     "kmscon" | "kmshaunt"
#   term     expected $TERM: "kmscon" (kmscon) / "xterm-ghostty" (kmshaunt, D6)
#   unit     console unit: kmsconvt@tty1.service / kmshaunt-vt@tty1.service
#   tty      "tty1"
{
  pkgs,
  kmshauntModule ? import ../module.nix,
}:
(import ./lib.nix pkgs).mkParityTest {
  name = "kmshaunt-m1-login";
  inherit kmshauntModule;

  # The body is identical for both implementations; everything that differs
  # between them is read from the injected variables above.
  scenario =
    _ctx: ''
      # S1 (M1.4 pty/login, M1.7 unit): autologin reaches an interactive shell on
      # the VT, and the child process sees the implementation's own $TERM.
      with subtest("S1 autologin and $TERM"):
          waitForLogin(machine)
          machine.send_chars("echo $TERM > /tmp/term\n")
          machine.wait_until_succeeds("test -s /tmp/term")
          shell_term = machine.succeed("cat /tmp/term").strip()
          assert shell_term == term, f"[{impl}] $TERM is {shell_term!r}, expected {term!r}"
          # Golden candidate: the autologin shell prompt. Always saved to the
          # test output; compared once nix/tests/goldens/ has the image.
          screenshotCompare(machine, impl, "S1-prompt")

      # S2 (M1.2 VT backend): ctrl-alt-f2 switches the VT away and ctrl-alt-f1
      # switches back with the screen restored. The active VT is read from the
      # kernel so the assertion does not depend on what happens to serve tty2;
      # the OCR check after returning proves the tty1 contents were redrawn.
      with subtest("S2 VT switch away and back"):
          marker = "parityok"
          machine.send_chars(f"echo {marker}\n")
          machine.wait_for_text(marker)
          machine.send_key("ctrl-alt-f2")
          machine.wait_until_succeeds("test $(cat /sys/class/tty/tty0/active) = tty2")
          machine.send_key("ctrl-alt-f1")
          machine.wait_until_succeeds("test $(cat /sys/class/tty/tty0/active) = tty1")
          machine.wait_for_text(marker)

      # S3 (M1.7 unit): the console unit dies, OnFailure=getty@%i takes over the
      # VT and an agetty login prompt appears. This tears the session down, so it
      # runs last.
      with subtest("S3 getty takes over when the console unit dies"):
          machine.succeed(f"systemctl kill --signal=SIGKILL {unit}")
          machine.wait_until_fails(f"systemctl is-active {unit}")
          machine.wait_for_unit(f"getty@{tty}.service")
          machine.wait_for_text("login:")
    '';
}