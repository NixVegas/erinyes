{ pkgs, testers, ... }:

let
  pkgsPath = pkgs.path;
  lpe = pkgs.callPackage ./lpe.nix { };
in
testers.runNixOSTest {
  name = "erinyes";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      lpe' = pkgs.callPackage ./lpe.nix { };
      checkTarget = pkgs.writeShellScriptBin "checkTarget" ''
        ${lpe.checkTarget}
        checkTarget
      '';
    in
    {
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };
      # needed for pintheft
      #boot.kernelModules = ["rds" "rds_tcp"];
      environment.systemPackages = [ checkTarget ];
      system.extraDependencies = [ pkgs.stdenvNoCC ] ++ lpe'.nativeBuildInputs;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.copy_from_host("${./lpe.nix}", "/home/alice/lpe.nix")
    machine.succeed("command -v checkTarget")
    machine.succeed("""sudo -u alice sh -c 'cd && exec nix-build --option substitute false -E "with import ${pkgsPath} {}; callPackage ./lpe.nix { }"' || true""")
    machine.fail("""
      # If this succeeds, it is very bad
      sudo -u alice checkTarget
    """)
  '';

  meta.maintainers = with pkgs.lib.maintainers; [ numinit ];
}
