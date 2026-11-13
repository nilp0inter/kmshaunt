# kmshaunt, built offline against the pinned libghostty-vt 1.0.1.
#
# This nixpkgs has no `zig.buildPackage`; the zig derivation provides a
# setup hook instead (zigConfigurePhase/zigBuildPhase/zigCheckPhase/
# zigInstallPhase), which is what nixpkgs' own zig packages use.
#
# Zig 0.17 keeps fetched packages in the project-local `zig-pkg/`
# directory. We pre-populate it from ../deps.nix (the libghostty-vt
# release dependency tarball plus libghostty-vt itself) so the sandbox
# build never needs the network. Real copies, not symlinks: Zig runs
# dependency build steps from inside the package directories and walks
# back out through `..`, which breaks on symlinked packages.
{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "kmshaunt";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
    ];
  };

  deps = callPackage ../deps.nix { };

  strictDeps = true;

  nativeBuildInputs = [ zig_0_17 ];

  postConfigure = ''
    mkdir -p zig-pkg
    cp -r ${finalAttrs.deps}/. zig-pkg/
    chmod -R u+w zig-pkg
  '';

  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "-Dcpu=baseline"
    "-Doptimize=ReleaseFast"
  ];

  doCheck = true;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/kmshaunt" --version | grep -F 'kmshaunt 0.0.1'
    runHook postInstallCheck
  '';

  meta = {
    description = "Linux KMS/DRM console on top of libghostty-vt";
    homepage = "https://github.com/nilp0inter/kmshaunt";
    mainProgram = "kmshaunt";
    platforms = lib.platforms.linux;
  };
})