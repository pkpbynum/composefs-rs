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
