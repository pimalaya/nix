rec {
  # v1.82.0
  rustToolchainFileSha256 = "yMuSb5eQPO/bHv+Bcf/US8LVMbf/G/0MSfiPwBhiPpk=";

  crossSystems = {
    aarch64-darwin = [
      "aarch64-apple-darwin"
    ];
    aarch64-linux = [
      "aarch64-unknown-linux-musl"
    ];
    x86_64-darwin = [
      "x86_64-apple-darwin"
    ];
    x86_64-linux = [
      "aarch64-unknown-linux-musl"
      "armv6l-unknown-linux-musleabihf"
      "armv7l-unknown-linux-musleabihf"
      "i686-unknown-linux-musl"
      "x86_64-unknown-linux-musl"
      "x86_64-w64-mingw32"
    ];
  };

  # make shell.nix
  mkShell =
    {
      nixpkgs ? <nixpkgs>,
      system ? builtins.currentSystem,
      pkgs ? import nixpkgs { inherit system; },
      fenix ? import (fetchTarball "https://github.com/nix-community/fenix/archive/monthly.tar.gz") { },
      buildInputs ? [ ],
      extraBuildInputs ? "",
    }:

    let
      inherit (pkgs) lib pkg-config;
      inherit (lib) optionals attrVals splitString;
      inherit (fenix) stable;

      rust = stable.withComponents [
        "cargo"
        "clippy"
        "rust-analyzer"
        "rust-src"
        "rustc"
        "rustfmt"
      ];

      extraBuildInputs' = optionals (extraBuildInputs != "") (
        attrVals (splitString "," extraBuildInputs) pkgs
      );

    in
    pkgs.mkShell {
      nativeBuildInputs = [ pkg-config ];
      buildInputs = [ rust ] ++ buildInputs ++ extraBuildInputs';
    };

  # make default.nix
  mkDefault =
    {
      nixpkgs ? <nixpkgs>,
      system ? builtins.currentSystem,
      pkgs ? import nixpkgs { inherit system; },
      crossPkgs ? import nixpkgs (
        {
          inherit system;
        }
        // (
          if target == null then
            { }
          else
            {
              crossSystem = {
                inherit isStatic;
                config = target;
              };
            }
        )
      ),
      fenix ? import (fetchTarball "https://github.com/nix-community/fenix/archive/monthly.tar.gz") { },
      target ? null,
      isStatic ? false,
      defaultFeatures ? true,
      features ? "",
      cargoLockFile ? src + "/Cargo.lock",
      src,
      mkPackage,
      version,
    }:

    let
      inherit (pkgs) binutils lib stdenv;
      inherit (crossPkgs) buildPlatform hostPlatform;
      inherit (lib) getExe' importTOML optional;
      inherit (hostPlatform) isWindows;

      # HACK: https://github.com/NixOS/nixpkgs/issues/177129
      # creates an empty libgcc_eh for Windows compiler to be happy
      libgcc_eh = stdenv.mkDerivation {
        pname = "empty-libgcc_eh";
        version = "0";
        dontUnpack = true;
        installPhase = ''
          mkdir -p "$out"/lib
          "${getExe' binutils "ar"}" r "$out"/lib/libgcc_eh.a
        '';
      };

      rustToolchain =
        let
          toolchain = fenix.stable;
          target = if buildPlatform == hostPlatform then null else hostPlatform.rust.rustcTarget;
          crossToolchain = fenix.targets.${target}.stable;
          components = [
            toolchain.rustc
            toolchain.cargo
          ]
          ++ optional (target != null) crossToolchain.rust-std;
        in
        fenix.combine components;

      rustPlatform = crossPkgs.makeRustPlatform {
        rustc = rustToolchain;
        cargo = rustToolchain;
      };

      package = mkPackage {
        inherit lib rustPlatform;
        inherit defaultFeatures features;
        pkgs = crossPkgs;
      };

    in
    package.overrideAttrs (drv: {
      inherit version;

      propagatedBuildInputs = (drv.propagatedBuildInputs or [ ]) ++ optional isWindows libgcc_eh;

      src = pkgs.nix-gitignore.gitignoreSource [ ] src;

      cargoDeps = rustPlatform.importCargoLock {
        lockFile = cargoLockFile;
        allowBuiltinFetchGit = true;
      };
    });

  # make flake outputs
  mkFlakeOutputs =
    {
      self,
      nixpkgs,
      fenix,
      ...
    }@inputs:
    {
      shell ? null,
      default ? null,
    }:

    let
      inherit (nixpkgs) lib;
      inherit (lib) optionalAttrs;

      pimalaya = import inputs.pimalaya;
      mkShell = args: import shell ({ inherit pimalaya nixpkgs; } // args);
      mkDefault = args: import default ({ inherit pimalaya nixpkgs; } // args);

      eachSystem = lib.genAttrs (lib.attrNames crossSystems);
      withGitEnvs =
        package:
        package.overrideAttrs (drv: {
          GIT_REV = drv.GIT_REV or self.rev or self.dirtyRev or "unknown";
          GIT_DESCRIBE = drv.GIT_DESCRIBE or "nix-flake-" + self.lastModifiedDate;
        });

      mkDevShell = system: {
        default = mkShell {
          inherit nixpkgs system;
          fenix = fenix.packages.${system};
        };
      };

      mkPackages =
        system:
        mkCrossPackages system
        // {
          default = withGitEnvs (mkDefault {
            inherit nixpkgs system;
            fenix = fenix.packages.${system};
          });
        };

      mkCrossPackages =
        system: lib.attrsets.mergeAttrsList (map (mkCrossPackage system) crossSystems.${system});

      mkCrossPackage =
        system: target:
        let
          crossSystem = {
            config = target;
            isStatic = true;
          };
          crossPkgs = import nixpkgs { inherit system crossSystem; };
          crossPkg = mkDefault {
            inherit nixpkgs system crossPkgs;
            fenix = fenix.packages.${system};
          };
        in
        {
          "cross-${crossPkgs.hostPlatform.system}" = withGitEnvs crossPkg;
        };

    in
    {
      devShells = optionalAttrs (shell != null) (eachSystem mkDevShell);
      packages = optionalAttrs (default != null) (eachSystem mkPackages);
    };
}
