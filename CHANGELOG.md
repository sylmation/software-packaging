# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- This changelog.

## 0.1.0 - 2026-08-27

First version of the packaging module. Nothing was released before this, so
everything below is new.

### Added

- `SCCMPackage` module and the `New-Package.ps1` entry point: command line
  creation of a Configuration Manager package (packaging mode) with an
  `Install` and an `Uninstall` standard program. No GUI and no application
  objects, so it can run from a build agent.
- `Config/SCCMPackage.config.json`, read by `Get-SCCMPackageConfig`, holding the
  site code, site server, content share, distribution point group, default
  manufacturer, client log path and program defaults. `SiteCode`, `SiteServer`
  and `PackageSourceRoot` are required; `-ConfigPath` selects a different file
  per environment.
- Metadata extraction with `Get-SCCMPackageMetadata`: manufacturer, product,
  version and product code from the MSI property table through the Windows
  Installer COM API, or from the version resource of an EXE. Each value can be
  overridden with a parameter.
- Silent switch detection with `Get-SCCMPackageSilentArgument`: `/qn /norestart`
  for MSI, and for EXE the engine is identified from the strings in the binary
  (Inno Setup, NSIS, WiX Burn, InstallShield, MSI wrapper). An unrecognised
  engine is refused rather than guessed, so `-SilentArguments` must be supplied.
- Generated `Install.ps1` and `Uninstall.ps1` wrappers that log to the
  configured client log path and return the installer's exit code, so `3010`
  still reaches Configuration Manager as a soft reboot. Uninstall uses
  `msiexec /x <ProductCode>` when a product code is known, otherwise the
  registry `QuietUninstallString`/`UninstallString`.
- Content staging to `<PackageSourceRoot>\<Manufacturer>\<Product>\<Version>`
  and distribution to the configured distribution point group, which
  `-SkipDistribution` turns off.
- `-WhatIf` on every side effect, forwarded across the module boundary by
  `New-Package.ps1`, so a full run can be previewed without touching the site or
  the content share.
- Pester suite under `Tests/` that runs without the Configuration Manager
  console, and a GitHub Actions workflow running it plus PSScriptAnalyzer on
  `windows-latest`.
