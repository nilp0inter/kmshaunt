# Offline Zig package set for kmshaunt: libghostty-vt 1.0.1 plus its full
# transitive dependency graph, laid out the way Zig 0.17's project-local
# package directory (`zig-pkg/`) expects — one directory per package, named
# by its Zig package hash.
#
# nixpkgs' zon2nix (0.1.3) cannot generate this file: it aborts with
# `error: parseError` on ghostty's build.zig.zon, which declares `.path`
# dependencies that zon2nix does not understand. Instead this follows the
# upstream packaging guide (PACKAGING-LIBGHOSTTY.md in the source tarball):
#
# - The official release dependency tarball carries the five transitive
#   packages (aro, highway, translate_c, uucode, wuffs — exactly the list in
#   the tarball's deps/libghostty-vt.txt) already unpacked, filtered by
#   `.paths` and named by their Zig hashes.
# - libghostty-vt itself is added with `zig fetch` on the unpacked source,
#   which applies the same `.paths` filtering and produces the hash directory
#   that build.zig.zon pins. `zig fetch` on a local path needs no network.
#
# The sandbox build copies this directory into `zig-pkg/` before building,
# so Zig finds every package locally and never touches the network.
{
  fetchurl,
  fetchzip,
  runCommand,
  zig_0_17,
}:
let
  version = "1.0.1";

  # The hash build.zig.zon pins for the ghostty dependency. The name inside
  # the hash is the manifest's own name/version (ghostty 1.4.1-dev), not the
  # release tarball's; LIB_VERSION in the tarball is 1.0.1.
  ghosttyHash = "ghostty-1.4.1-dev-5UdBC7mPUgFIzAVXNJOixiryPYogwYwnmN0zZWud4iSr";

  # Unpacked source directory (fetchzip strips the tarball root). `zig fetch`
  # must be given this directory, not the raw tarball: on a tarball it keeps
  # the archive's root dir inside the hash dir, double-nesting the package.
  src = fetchzip {
    url = "https://release.files.ghostty.org/libghostty-vt/${version}/libghostty-vt-${version}.tar.gz";
    hash = "sha256-zGuLawiLRplgXoWllDefbR+QYoEiS0MhHG+EKWFFMjI=";
  };

  deps = fetchurl {
    url = "https://release.files.ghostty.org/libghostty-vt/${version}/libghostty-vt-${version}-deps.tar.gz";
    hash = "sha256-kaThCWClK/W/SxWqKizdr/ionWzZA9MFW9pP0X3jNW0=";
  };
in
runCommand "kmshaunt-zig-packages-${version}"
  {
    nativeBuildInputs = [ zig_0_17 ];
  }
  ''
    mkdir -p "$out"

    # The five transitive packages, already in Zig's cache layout.
    tar -xzf ${deps} --strip-components=1 -C "$out"

    # libghostty-vt itself: let Zig filter it by `.paths` and name it by its
    # hash. Without `--save`, Zig 0.17 keeps the filtered package as
    # p/<hash>.tar.gz in the global cache; unpacking that gives the hash
    # directory the build expects.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    hash="$(zig fetch ${src})"
    if [ "$hash" != "${ghosttyHash}" ]; then
      echo "libghostty-vt-${version} has Zig hash $hash, expected ${ghosttyHash}" >&2
      exit 1
    fi
    tar -xzf "$ZIG_GLOBAL_CACHE_DIR/p/$hash.tar.gz" -C "$out"
  ''