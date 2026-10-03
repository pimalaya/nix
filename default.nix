rec {
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
    }:

    let
      inherit (fenix) stable;
      inherit (pkgs) pkg-config nixd nixfmt-rfc-style;

      rust = stable.withComponents [
        "cargo"
        "clippy"
        "rust-analyzer"
        "rust-src"
        "rustc"
        "rustfmt"
      ];

    in
    pkgs.mkShell {
      nativeBuildInputs = [ pkg-config ];
      buildInputs = [
        nixd
        nixfmt-rfc-style
        rust
      ];
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
      inherit (crossPkgs.stdenv) buildPlatform hostPlatform;
      inherit (lib)
        any
        concatStringsSep
        filter
        getExe'
        getName
        importTOML
        optional
        optionals
        optionalAttrs
        optionalString
        remove
        splitString
        ;
      inherit (hostPlatform) isDarwin isWindows;

      cargoDefaultFeatures = ((importTOML (src + "/Cargo.toml")).features or { }).default or [ ];

      buildFeatures = concatStringsSep "," (
        optionals defaultFeatures (remove "vendored" cargoDefaultFeatures)
        ++ filter (feature: feature != "") (splitString "," features)
      );

      # HACK: empty libgcc_eh for the Windows compiler
      # https://github.com/nixos/nixpkgs/issues/177129
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
        defaultFeatures = false;
        features = buildFeatures;
        pkgs = crossPkgs;
        buildPackages = pkgs.buildPackages;
      };

    in
    package.overrideAttrs (
      drv:
      let
        linksSqlite = any (input: getName input == "sqlite") (drv.buildInputs or [ ]);
      in
      {
        inherit version;

        # HACK: stops the libiconv setup-hook adding -liconv; Rust's libc
        # crate still links it, rewritten in postFixup.
        dontAddExtraLibs = true;

        # HACK: points the store libiconv at the ABI-compatible one macOS
        # ships, so the binary loads without Nix, then re-signs (required by
        # Apple Silicon, voided by install_name_tool).
        postFixup =
          (drv.postFixup or "")
          + optionalString isDarwin ''
            for bin in "$out"/bin/*; do
              for lib in $(otool -L "$bin" | grep -o '/nix/store/[^[:space:]]*libiconv[^[:space:]]*\.dylib' || true); do
                install_name_tool -change "$lib" /usr/lib/libiconv.2.dylib "$bin"
              done
              codesign -f -s - "$bin"
            done
          '';

        # NOTE: provides the `codesign` postFixup needs.
        nativeBuildInputs = (drv.nativeBuildInputs or [ ]) ++ optional isDarwin crossPkgs.darwin.sigtool;

        propagatedBuildInputs = (drv.propagatedBuildInputs or [ ]) ++ optional isWindows libgcc_eh;

        # NOTE: links SQLite statically (with its private zlib), else Darwin
        # native builds would load it from /nix/store.
        buildInputs =
          (drv.buildInputs or [ ]) ++ optional linksSqlite (crossPkgs.zlib.static or crossPkgs.zlib);

        env = (drv.env or { }) // optionalAttrs linksSqlite { SQLITE3_STATIC = "1"; };

        src = pkgs.nix-gitignore.gitignoreSource [ ] src;

        cargoDeps = rustPlatform.importCargoLock {
          lockFile = cargoLockFile;
          allowBuiltinFetchGit = true;
        };
      }
    );

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
      mkDefault = lib.makeOverridable (args: import default ({ inherit pimalaya nixpkgs; } // args));

      eachSystem = lib.genAttrs (lib.attrNames crossSystems);

      withGitEnvs =
        package:
        package.overrideAttrs (drv: {
          env = (drv.env or { }) // {
            GIT_REV = drv.env.GIT_REV or self.rev or self.dirtyRev or "unknown";
            GIT_DESCRIBE = drv.env.GIT_DESCRIBE or ("nix-flake-" + self.lastModifiedDate);
          };
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
          # NOTE: builds natively when target is the build platform, cross
          # mode breaking Darwin builds. Compares `parsed` since `.system`
          # ignores the libc (gnu vs musl).
          isSelfCross =
            (nixpkgs.lib.systems.elaborate { inherit system; }).parsed
            == (nixpkgs.lib.systems.elaborate { config = target; }).parsed;

          crossPkgs =
            if isSelfCross then
              import nixpkgs { inherit system; }
            else
              import nixpkgs {
                inherit system;
                crossSystem = {
                  config = target;
                  isStatic = true;
                };
              };
          crossPkg = mkDefault {
            inherit nixpkgs system crossPkgs;
            fenix = fenix.packages.${system};
          };
        in
        {
          "cross-${crossPkgs.stdenv.hostPlatform.system}" = withGitEnvs crossPkg;
        };

    in
    {
      devShells = optionalAttrs (shell != null) (eachSystem mkDevShell);
      packages = optionalAttrs (default != null) (eachSystem mkPackages);
    };
}
