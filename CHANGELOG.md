# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Native macOS app for browsing installed applications by size or last-opened
  date, including apps in subfolders of the standard application directories.
- Disk-use measurement for app bundles and bundle-identifier-related user
  Library files, with incomplete or inaccessible measurements shown as lower
  bounds and container scans deferred behind an explicit choice.
- Removal review for the app bundle and selected related files, including
  shared-file protection, stale-file revalidation, vendor uninstaller
  discovery, Trash recovery, and administrator authorization when needed.
- Project tooling: `scripts/build.sh` and `scripts/release.sh`, CI and
  tag-triggered release workflows, Dependabot, the GLM/StepFun review
  workflow, and agent instructions.
