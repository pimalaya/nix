# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added `.override` to the packages `mkFlakeOutputs` exposes (`default` and `cross-*`), so a downstream flake can change `mkDefault` arguments such as `defaultFeatures` and `features`.

### Changed

- Changed `mkDefault` to build a project's default cargo features without `vendored`, so native libraries come from Nix rather than from a source build.

### Fixed

- Fixed git metadata not reaching build scripts: `GIT_REV` and `GIT_DESCRIBE` are now set through `env`, which structuredAttrs exports, instead of plain attributes, which it only declares.
- Fixed Darwin binaries loading SQLite from `/nix/store`, which no Mac without Nix has: a package linking SQLite now links the store's static archive (`SQLITE3_STATIC`) on every platform.
