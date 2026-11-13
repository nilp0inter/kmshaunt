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