{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  outputs =
    { self, nixpkgs, ... }:
    let
      cargoToml = fromTOML (builtins.readFile ./Cargo.toml);
      inherit (nixpkgs.legacyPackages.x86_64-linux.lib) fileset;
      forAllSystems =
        fn:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: fn nixpkgs.legacyPackages.${system});
    in
    {
      legacyPackages = forAllSystems (pkgs: pkgs);
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.composefs;
        cfs-oci-example =
          let
            cfsctl = self.packages.${pkgs.stdenv.hostPlatform.system}.composefs;
            container = pkgs.ociTools.buildContainer {
              args = [ "${pkgs.coreutils}/bin/true" ];
            };
          in
          pkgs.runCommand "cfs-oci-example" {
            nativeBuildInputs = [ cfsctl ];
          } ''
            cfsctl --repo $out init --insecure
            cfsctl --repo $out create-image --no-propagate-usr-to-root ${container}/rootfs
          '';
        composefs = pkgs.rustPlatform.buildRustPackage {
          pname = "composefs";
          inherit (cargoToml.workspace.package) version;
          nativeBuildInputs = with pkgs; [
            pkg-config
          ];
          buildInputs = with pkgs; [
            openssl
          ];
          src = fileset.toSource {
            root = ./.;
            fileset = fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./crates
            ];
          };
          cargoLock.lockFile = ./Cargo.lock;
          checkFlags = [
            # Requires fsverity kernel support, unavailable in the sandbox
            "--skip=fsverity"
            # Requires mkcomposefs to be installed
            "--skip=erofs::reader::tests::test_pr188_empty_inline_directory"
          ];
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "composefs";
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.composefs ];
          packages = with pkgs; [
            rust-analyzer
            clippy
            just
          ];
        };
      });

      checks = forAllSystems (
        pkgs:
        {
          vm-cfsctl = pkgs.testers.runNixOSTest {
            name = "cfsctl-mount";
            nodes.machine =
              { pkgs, ... }:
              let
                cfsctl = self.packages.${pkgs.stdenv.hostPlatform.system}.composefs;
                container = pkgs.ociTools.buildContainer {
                  args = [ "${pkgs.coreutils}/bin/true" ];
                };
              in
              {
                virtualisation.memorySize = 2048;
                environment.systemPackages = [ cfsctl ];
                systemd.tmpfiles.rules = [
                  "C /var/lib/test-rootfs - - - - ${container}/rootfs"
                ];
              };
            testScript = ''
              machine.wait_for_unit("multi-user.target")

              # Initialize a composefs repository
              machine.succeed("cfsctl --repo /tmp/repo init --insecure")

              # Create a composefs image from the OCI rootfs
              result = machine.succeed(
                  "cfsctl --repo /tmp/repo create-image --no-propagate-usr-to-root /var/lib/test-rootfs"
              )
              image_id = result.strip().split(":")[-1]

              # Mount the image
              machine.succeed("mkdir -p /mnt/composefs")
              machine.succeed(
                  f"cfsctl --repo /tmp/repo mount {image_id} /mnt/composefs"
              )

              # Verify that the nix store path for coreutils is accessible
              machine.succeed("test -d /mnt/composefs/nix/store")
              machine.succeed("find /mnt/composefs -name true -executable | grep -q true")
            '';
          };
        }
      );
    };
}
