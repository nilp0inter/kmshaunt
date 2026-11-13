[script]
write-flake:
    set -euo pipefail
    # Pass 1: regenerate flake.nix from current modules and prune the lock.
    nix run --accept-flake-config .#write-flake
    # Capture allfollow's transitive follows as a flake-file module so
    # flake.nix declares them and nix evaluation stays stable (otherwise
    # every `nix flake metadata` re-introduces the duplicate transitive
    # nodes that allfollow's prune just collapsed). Write to a temp file
    # first so a failed allfollow invocation doesn't truncate the existing
    # valid module to zero bytes (which would make the flake un-evaluable).
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    nix run --accept-flake-config .#allfollow -- config flake.lock > "$tmp"
    mv "$tmp" modules/flake/auto-follows.nix
    # Pass 2: re-run with the new follows visible so they end up in flake.nix.
    nix run --accept-flake-config .#write-flake

flake-check:
    nix flake check --accept-flake-config

# M8 performance benchmark (ROADMAP M8.1/M8.3): boots ONE VM with kmscon on
# tty2 and kmshaunt on tty1, runs the full vtebench suite against each in
# turn, and measures peak RSS after filling the 10,000-line scrollback.
# Numbers land in the build log and in ./result (perf-summary.txt, perf.json,
# raw *.dat, screenshots, env.txt). The console binary is built with the
# unit-test gate disabled, as for update-goldens: the benchmark measures the
# installed binary, so peers' in-flight src edits must not block it.
m8-perf:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build --accept-flake-config --impure --print-build-logs --expr '
      let
        flake = builtins.getFlake (toString ./.);
        system = builtins.currentSystem;
        pkgs = import flake.inputs.nixpkgs {
          inherit system;
          overlays = [ (import ./nix/overlay.nix) ];
        };
      in import ./nix/tests/m8-perf.nix {
        inherit pkgs;
        kmshauntModule = {
          imports = [ ./nix/module.nix ];
          services.kmshaunt.package =
            flake.packages.${system}.kmshaunt.overrideAttrs { doCheck = false; };
        };
      }'

# Regenerate the T2 render goldens (ROADMAP R6). Builds the pinned renderer
# with the golden check disabled (the point is to replace the goldens), then
# re-blesses every fixture. Review the image diff before committing: a
# flake.lock bump that changes FreeType/HarfBuzz/fontconfig or the font bytes
# changes pixels. T3 VM goldens are regenerated separately by running
# `nix build .#checks.<system>.kmshaunt-render-golden-vm` and copying its
# screenshots into nix/tests/goldens/ (see nix/tests/render-golden-vm.nix).
update-goldens:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
    tool=$(nix build --accept-flake-config --impure --no-link --print-out-paths \
        --expr "(builtins.getFlake (toString ./.)).packages.${system}.render-golden.overrideAttrs { doCheck = false; }")
    for fixture in fixtures/t2/*.bin; do
        stem=$(basename "$fixture" .bin)
        "$tool/bin/render_golden" --fixture "$fixture" \
            --generate --out "fixtures/t2/goldens/$stem.png"
    done
    # Second golden from the animation fixture: frame 2, due at 40 ms.
    "$tool/bin/render_golden" --fixture fixtures/t2/kitty-animation.bin \
        --animation-ms 40 --generate --out fixtures/t2/goldens/kitty-animation-frame2.png