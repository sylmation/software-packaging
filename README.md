# software-packaging

PowerShell module that turns an `.msi` or `.exe` installer into a Configuration
Manager **package** (packaging mode, not application mode) with an **Install**
and an **Uninstall** program. Everything is command line driven so it can run
from a build agent.

## Layout

| Path | Purpose |
| --- | --- |
| `SCCMPackage/SCCMPackage.psm1` | All module functions. |
| `SCCMPackage/SCCMPackage.psd1` | Module manifest. |
| `SCCMPackage/Templates/` | Install and uninstall wrapper script templates. |
| `Config/SCCMPackage.config.json` | Site code, site server, content share, DP group, program defaults. |
| `New-Package.ps1` | CLI entry point. |
| `Tests/` | Pester tests. |

## Configuration

Edit `Config/SCCMPackage.config.json` before the first run:

```json
{
    "SiteCode": "PS1",
    "SiteServer": "cm01.contoso.com",
    "PackageSourceRoot": "\\\\cm01\\Sources$\\Packages",
    "DistributionPointGroup": "All Distribution Points",
    "Manufacturer": "Contoso",
    "LogPath": "C:\\Windows\\Logs\\SCCMPackage"
}
```

`SiteCode`, `SiteServer` and `PackageSourceRoot` are required. Pass
`-ConfigPath` to use a different file, for example one per environment.

## Usage

```powershell
# Preview everything without touching the site or the content share
.\New-Package.ps1 -SourcePath C:\Sources\7zip -WhatIf

# Create the package, the two programs, and distribute the content
.\New-Package.ps1 -SourcePath C:\Sources\7zip

# An exe whose silent switches cannot be detected
.\New-Package.ps1 -SourcePath C:\Sources\Reader\Reader.exe -SilentArguments '/sAll /rs'
```

Or import the module and call the functions directly:

```powershell
Import-Module .\SCCMPackage\SCCMPackage.psd1
Get-SCCMPackageMetadata -SourcePath C:\Sources\7zip
New-SCCMPackage -SourcePath C:\Sources\7zip -SkipDistribution
```

## What happens

1. The installer is located in `-SourcePath` (a folder with exactly one
   installer, or the installer file itself).
2. Manufacturer, product, version and product code are read from the MSI
   database, or from the file version information of an exe. Any of them can be
   overridden with a parameter.
3. Silent switches are chosen: `/qn /norestart` for an MSI, otherwise they are
   guessed from the strings inside the exe (Inno Setup, NSIS, WiX burn,
   InstallShield, MSI wrapper). If nothing matches, `-SilentArguments` is
   required.
4. The content is copied to `PackageSourceRoot\<Manufacturer>\<Product>\<Version>`
   and `Install.ps1` / `Uninstall.ps1` are generated next to it.
5. A `CMPackage` is created with an `Install` and an `Uninstall` standard
   program, then distributed to the configured distribution point group
   (skip with `-SkipDistribution`).

The generated scripts log to `LogPath` on the client and return the installer
exit code, so Configuration Manager reports the real result. The uninstall
script uses `msiexec /x <ProductCode>` for MSI packages and the registry
uninstall string for exe packages.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Configuration Manager console installed (for the `ConfigurationManager`
  module) on the machine that creates the package
- Write access to the content share

Only `New-SCCMPackage` needs the console; metadata extraction and script
generation work anywhere, which is what the tests exercise.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path .\Tests
```
