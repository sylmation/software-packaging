<#
    .SYNOPSIS
        Command line entry point for creating a Configuration Manager package.

    .DESCRIPTION
        Imports the SCCMPackage module from the repository and creates a package
        in packaging mode for the installer in -SourcePath. Intended to be called
        from a build agent, so it returns a non zero exit code on failure.

    .EXAMPLE
        .\New-Package.ps1 -SourcePath C:\Sources\7zip

    .EXAMPLE
        .\New-Package.ps1 -SourcePath C:\Sources\Reader\Reader.exe -SilentArguments '/sAll /rs' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Config\SCCMPackage.config.json'),

    [string]$PackageName,

    [string]$Manufacturer,

    [string]$Product,

    [string]$Version,

    [string]$SilentArguments,

    [switch]$SkipDistribution
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'SCCMPackage\SCCMPackage.psd1') -Force

$arguments = @{
    SourcePath = $SourcePath
    ConfigPath = $ConfigPath
}
foreach ($name in 'PackageName', 'Manufacturer', 'Product', 'Version', 'SilentArguments', 'SkipDistribution') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $arguments[$name] = $PSBoundParameters[$name]
    }
}

# -WhatIf does not cross the module boundary on its own, so it is forwarded.
if ($WhatIfPreference) {
    $arguments['WhatIf'] = $true
}

try {
    New-SCCMPackage @arguments
}
catch {
    Write-Error $_
    exit 1
}
