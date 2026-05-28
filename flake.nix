{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  outputs =
    { self, nixpkgs, ... }:
    let
      cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
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
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.composefs;
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
            # These require fsverity kernel support, unavailable in the sandbox
            "--skip=fsverity::ioctl::tests::test_measure_verity_opt"
            "--skip=fsverity::tests::crosscheck_interesting_cases"
            "--skip=fsverity::tests::test_enable_verity_maybe_copy_with_copy"
            "--skip=fsverity::tests::test_enable_verity_maybe_copy_without_copy"
            "--skip=fsverity::tests::test_verity_forking"
            "--skip=fsverity::tests::test_verity_missing"
            "--skip=fsverity::tests::test_verity_simple"
            "--skip=fsverity::tests::test_verity_wrongdigest_sha256_sha512"
            "--skip=fsverity::tests::test_verity_wrongdigest_sha512_sha256"
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
          ];
        };
      });
    };
}
