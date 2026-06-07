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
        getExe'
        importTOML
        optional
        optionalString
        ;
      inherit (hostPlatform) isDarwin isWindows;

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
        buildPackages = pkgs.buildPackages;
      };

    in
    package.overrideAttrs (drv: {
      inherit version;

      # HACK: stops the nixpkgs libiconv setup-hook appending -liconv to
      # NIX_LDFLAGS. It does NOT stop Rust's libc crate emitting its own
      # -liconv, which the linker still resolves to the store libiconv; that
      # leftover store path is rewritten in postFixup below.
      dontAddExtraLibs = true;

      # HACK: Rust's libc crate links -liconv, baked by the linker into an
      # LC_LOAD_DYLIB pointing at the store libiconv; the binary then fails to
      # load on any Mac without that /nix/store path. nixpkgs libiconv is
      # built ABI-compatible with Apple's, so rewrite the load command to the
      # libiconv every macOS ships, then re-sign (install_name_tool voids the
      # ad-hoc signature Apple Silicon requires at load time).
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
          # When `target` elaborates to the same platform as the build
          # (e.g. aarch64-darwin -> aarch64-apple-darwin), keep things native:
          # setting crossSystem here would flip nixpkgs into cross-compile mode
          # (prefixed compilers, autotools cross_compiling=yes) and
          # isStatic=true would pull in pkgsStatic, which on Darwin
          # source-builds tools like atf whose configure scripts cannot run
          # probe binaries under cross semantics.
          #
          # Compare the full `parsed` record, not `.system`: the short form is
          # libc-agnostic so it cannot distinguish e.g.  x86_64-linux-gnu from
          # x86_64-linux-musl, both of which share `.system = "x86_64-linux"`
          # but are genuinely different cross targets.
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
