# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Fixed git metadata not reaching build scripts: `GIT_REV` and `GIT_DESCRIBE` are now set through `env`, which structuredAttrs exports, instead of plain attributes, which it only declares.
