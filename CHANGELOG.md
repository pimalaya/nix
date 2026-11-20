# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `.override` to the packages `mkFlakeOutputs` exposes (`default` and `cross-*`), so a downstream flake can change `mkDefault` arguments such as `defaultFeatures` and `features`.
- Added a version check to the release workflow: a tag whose name, without its `v`, is not the version of the root manifest's package fails the publishing job before it builds, so no binary is uploaded and nothing is published to crates.io.
- Added pre-release marking to the release workflow: a tag holding `-` (such as `v1.0.0-rc.1`) makes a GitHub pre-release, never marked latest, so install scripts reading `releases/latest` keep the last stable release.

### Changed

- Changed the shell code formatter from `nixfmt-rfc-style` to `nixfmt`, its name since nixpkgs 25.11, which warns on the old one.
- Changed `mkDefault` to build a project's default cargo features without `vendored`, so native libraries come from Nix rather than from a source build.

### Fixed

- Fixed git metadata not reaching build scripts: `GIT_REV` and `GIT_DESCRIBE` are now set through `env`, which structuredAttrs exports, instead of plain attributes, which it only declares.
- Fixed Darwin binaries loading SQLite from `/nix/store`, which no Mac without Nix has: a package linking SQLite now links the store's static archive (`SQLITE3_STATIC`) on every platform.
- Fixed `x86_64-darwin` outputs failing to evaluate since fenix's flake dropped that system: `mkFlakeOutputs` now imports fenix directly there.
- Fixed the Windows release zip holding the binary twice and the tgz, but no share directory: it now holds what the tgz does.
