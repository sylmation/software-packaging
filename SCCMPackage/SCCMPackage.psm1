#Requires -Version 5.1

Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:TemplateRoot = Join-Path $PSScriptRoot 'Templates'
$script:DefaultConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\SCCMPackage.config.json'
$script:LogPath = Join-Path $env:TEMP 'SCCMPackage.log'

function Write-SCCMPackageLog {
    <#
        .SYNOPSIS
            Writes a timestamped line to the module log and to the pipeline host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level.ToUpperInvariant(), $Message

    $directory = Split-Path -Parent $script:LogPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    Add-Content -LiteralPath $script:LogPath -Value $line

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error $Message }
        default { Write-Verbose $line -Verbose }
    }
}

function Set-SCCMPackageLogPath {
    <#
        .SYNOPSIS
            Redirects the module log file, which is useful inside a pipeline agent.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Set module log path')) {
        $script:LogPath = $Path
    }
}

function Get-SCCMPackageConfig {
    <#
        .SYNOPSIS
            Reads the JSON configuration that describes the site and the content share.

        .DESCRIPTION
            Defaults to Config\SCCMPackage.config.json in the repository so that the
            module can be used without arguments from a build agent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path = $script:DefaultConfigPath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file '$Path' was not found."
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    foreach ($required in 'SiteCode', 'SiteServer', 'PackageSourceRoot') {
        if (-not $config.PSObject.Properties.Name.Contains($required) -or -not $config.$required) {
            throw "Configuration file '$Path' is missing the '$required' value."
        }
    }

    if ($config.PSObject.Properties.Name -contains 'LogPath' -and $config.LogPath) {
        $script:LogPath = Join-Path $config.LogPath 'SCCMPackage.log'
    }

    $config
}

function Get-SCCMPackageInstaller {
    <#
        .SYNOPSIS
            Finds the single .msi or .exe installer inside a source folder.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Source path '$SourcePath' was not found."
    }

    $item = Get-Item -LiteralPath $SourcePath
    if (-not $item.PSIsContainer) {
        if ($item.Extension -notin '.msi', '.exe') {
            throw "'$SourcePath' is not an .msi or .exe installer."
        }
        return $item
    }

    $installers = @(Get-ChildItem -LiteralPath $SourcePath -File |
            Where-Object { $_.Extension -in '.msi', '.exe' })

    if ($installers.Count -eq 0) {
        throw "No .msi or .exe installer was found in '$SourcePath'."
    }
    if ($installers.Count -gt 1) {
        $names = ($installers.Name -join ', ')
        throw "More than one installer was found in '$SourcePath' ($names). Pass the installer file directly."
    }

    $installers[0]
}

function Get-SCCMPackageMsiProperty {
    <#
        .SYNOPSIS
            Reads a property out of an MSI database through the Windows Installer COM API.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Property
    )

    $installer = $null
    $database = $null
    $view = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $query = "SELECT Value FROM Property WHERE Property = '$Property'"
        $view = $database.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $database, @($query))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $record) {
            return $null
        }
        $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
    }
    catch {
        Write-SCCMPackageLog -Message "Unable to read MSI property '$Property' from '$Path': $($_.Exception.Message)" -Level Warning
        $null
    }
    finally {
        foreach ($comObject in $view, $database, $installer) {
            if ($comObject) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($comObject)
            }
        }
    }
}

function Get-SCCMPackageSilentArgument {
    <#
        .SYNOPSIS
            Returns the silent switches for an installer.

        .DESCRIPTION
            MSI packages always use /qn /norestart. For an .exe the installer
            technology is guessed from the strings embedded in the binary, which
            covers Inno Setup, NSIS, InstallShield, WiX burn and MSI wrappers.
            An empty string is returned when the technology cannot be identified,
            so the caller can supply switches explicitly.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::GetExtension($Path) -eq '.msi') {
        return [pscustomobject]@{
            InstallerTechnology = 'MSI'
            SilentArguments     = '/qn /norestart'
            SilentUninstallArguments = '/qn /norestart'
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
    $content = $text + $unicode

    $technology, $install, $uninstall = switch -Regex ($content) {
        'Inno Setup' { 'InnoSetup', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; break }
        'Nullsoft\.NSIS' { 'NSIS', '/S', '/S'; break }
        'WixBurn' { 'Burn', '/quiet /norestart', '/quiet /norestart'; break }
        'InstallShield' { 'InstallShield', '/s /v"/qn /norestart"', '/s /v"/qn /norestart"'; break }
        'Windows Installer XML|msiexec' { 'MsiWrapper', '/quiet /norestart', '/quiet /norestart'; break }
        default { 'Unknown', '', ''; break }
    }

    [pscustomobject]@{
        InstallerTechnology      = $technology
        SilentArguments          = $install
        SilentUninstallArguments = $uninstall
    }
}

function Get-SCCMPackageMetadata {
    <#
        .SYNOPSIS
            Collects the manufacturer, product, version and silent switches for an installer.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$Manufacturer,

        [string]$Product,

        [string]$Version,

        [string]$SilentArguments
    )

    $installer = Get-SCCMPackageInstaller -SourcePath $SourcePath
    $isMsi = $installer.Extension -eq '.msi'
    $detected = Get-SCCMPackageSilentArgument -Path $installer.FullName
    $productCode = $null

    if ($isMsi) {
        $manufacturerValue = Get-SCCMPackageMsiProperty -Path $installer.FullName -Property 'Manufacturer'
        $productValue = Get-SCCMPackageMsiProperty -Path $installer.FullName -Property 'ProductName'
        $versionValue = Get-SCCMPackageMsiProperty -Path $installer.FullName -Property 'ProductVersion'
        $productCode = Get-SCCMPackageMsiProperty -Path $installer.FullName -Property 'ProductCode'
    }
    else {
        $info = $installer.VersionInfo
        $manufacturerValue = $info.CompanyName
        $productValue = $info.ProductName
        $versionValue = $info.ProductVersion
    }

    if (-not $productValue) {
        $productValue = [System.IO.Path]::GetFileNameWithoutExtension($installer.Name)
    }
    if (-not $versionValue) {
        $versionValue = '1.0.0'
    }
    if (-not $manufacturerValue) {
        $manufacturerValue = 'Unknown'
    }

    [pscustomobject]@{
        InstallerPath            = $installer.FullName
        InstallerFile            = $installer.Name
        SourceDirectory          = $installer.DirectoryName
        InstallerType            = if ($isMsi) { 'MSI' } else { 'EXE' }
        InstallerTechnology      = $detected.InstallerTechnology
        Manufacturer             = if ($Manufacturer) { $Manufacturer } else { $manufacturerValue.Trim() }
        Product                  = if ($Product) { $Product } else { $productValue.Trim() }
        Version                  = if ($Version) { $Version } else { $versionValue.Trim() }
        ProductCode              = $productCode
        SilentArguments          = if ($PSBoundParameters.ContainsKey('SilentArguments')) { $SilentArguments } else { $detected.SilentArguments }
        SilentUninstallArguments = $detected.SilentUninstallArguments
    }
}

function New-SCCMPackageScript {
    <#
        .SYNOPSIS
            Renders the install and uninstall wrapper scripts next to the installer.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Metadata,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$PackageName,

        [string]$LogPath = 'C:\Windows\Logs\SCCMPackage'
    )

    if (-not $PackageName) {
        $PackageName = '{0} {1} {2}' -f $Metadata.Manufacturer, $Metadata.Product, $Metadata.Version
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        if ($PSCmdlet.ShouldProcess($Destination, 'Create destination directory')) {
            New-Item -Path $Destination -ItemType Directory -Force | Out-Null
        }
    }

    $tokens = @{
        '{{PackageName}}'              = $PackageName
        '{{GeneratedOn}}'              = (Get-Date -Format 'u')
        '{{Manufacturer}}'             = $Metadata.Manufacturer
        '{{Product}}'                  = $Metadata.Product
        '{{Version}}'                  = $Metadata.Version
        '{{InstallerFile}}'            = $Metadata.InstallerFile
        '{{InstallerType}}'            = $Metadata.InstallerType
        '{{SilentArguments}}'          = $Metadata.SilentArguments
        '{{SilentUninstallArguments}}' = $Metadata.SilentUninstallArguments
        '{{ProductCode}}'              = $Metadata.ProductCode
        '{{LogPath}}'                  = $LogPath
    }

    $results = [ordered]@{}

    foreach ($name in 'Install', 'Uninstall') {
        $template = Join-Path $script:TemplateRoot "$name.ps1.template"
        if (-not (Test-Path -LiteralPath $template)) {
            throw "Template '$template' was not found."
        }

        $content = Get-Content -LiteralPath $template -Raw
        foreach ($token in $tokens.GetEnumerator()) {
            $content = $content.Replace($token.Key, [string]$token.Value)
        }

        $target = Join-Path $Destination "$name.ps1"
        if ($PSCmdlet.ShouldProcess($target, "Write $name script")) {
            Set-Content -LiteralPath $target -Value $content -Encoding UTF8
            Write-SCCMPackageLog -Message "Wrote '$target'."
        }
        $results["${name}Script"] = $target
    }

    [pscustomobject]$results
}

function Connect-SCCMPackageSite {
    <#
        .SYNOPSIS
            Imports the ConfigurationManager module and returns the site PSDrive name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SiteCode,

        [Parameter(Mandatory)]
        [string]$SiteServer
    )

    if (-not (Get-Module -Name ConfigurationManager)) {
        if (-not $env:SMS_ADMIN_UI_PATH) {
            throw 'The ConfigurationManager module was not found (SMS_ADMIN_UI_PATH is not set). Install the Configuration Manager console on this machine.'
        }
        $modulePath = Join-Path (Split-Path -Parent $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1'
        if (-not (Test-Path -LiteralPath $modulePath)) {
            throw "The ConfigurationManager module was not found at '$modulePath'."
        }
        Import-Module $modulePath -ErrorAction Stop
    }

    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Scope Script | Out-Null
    }

    Write-SCCMPackageLog -Message "Connected to site $SiteCode on $SiteServer."
    "${SiteCode}:"
}

function New-SCCMPackage {
    <#
        .SYNOPSIS
            Creates a Configuration Manager package (packaging mode) with install and
            uninstall programs for an .msi or .exe installer.

        .DESCRIPTION
            Stages the source content on the content share, generates the wrapper
            scripts, creates the legacy Package plus an Install and an Uninstall
            Program, and distributes the content to the configured distribution
            point group. No application objects are created.

        .EXAMPLE
            New-SCCMPackage -SourcePath C:\Sources\7zip -Verbose

        .EXAMPLE
            New-SCCMPackage -SourcePath C:\Sources\Reader\Reader.exe -SilentArguments '/sAll /rs' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$ConfigPath = $script:DefaultConfigPath,

        [string]$PackageName,

        [string]$Manufacturer,

        [string]$Product,

        [string]$Version,

        [string]$SilentArguments,

        [switch]$SkipDistribution
    )

    $config = Get-SCCMPackageConfig -Path $ConfigPath

    $metadataParameters = @{ SourcePath = $SourcePath }
    foreach ($name in 'Manufacturer', 'Product', 'Version', 'SilentArguments') {
        if ($PSBoundParameters.ContainsKey($name)) {
            $metadataParameters[$name] = $PSBoundParameters[$name]
        }
    }
    if (-not $metadataParameters.ContainsKey('Manufacturer') -and $config.Manufacturer) {
        $metadataParameters['Manufacturer'] = $config.Manufacturer
    }

    $metadata = Get-SCCMPackageMetadata @metadataParameters

    if ($metadata.InstallerType -eq 'EXE' -and -not $metadata.SilentArguments) {
        throw "Silent switches could not be detected for '$($metadata.InstallerFile)'. Pass -SilentArguments explicitly."
    }

    if (-not $PackageName) {
        $PackageName = '{0} {1} {2}' -f $metadata.Manufacturer, $metadata.Product, $metadata.Version
    }

    $contentPath = Join-Path $config.PackageSourceRoot (Join-Path $metadata.Manufacturer (Join-Path $metadata.Product $metadata.Version))

    if ($PSCmdlet.ShouldProcess($contentPath, 'Stage package content')) {
        if (-not (Test-Path -LiteralPath $contentPath)) {
            New-Item -Path $contentPath -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $metadata.SourceDirectory '*') -Destination $contentPath -Recurse -Force
        Write-SCCMPackageLog -Message "Staged content in '$contentPath'."
    }

    $logPath = if ($config.PSObject.Properties.Name -contains 'LogPath' -and $config.LogPath) { $config.LogPath } else { 'C:\Windows\Logs\SCCMPackage' }
    $scripts = New-SCCMPackageScript -Metadata $metadata -Destination $contentPath -PackageName $PackageName -LogPath $logPath

    $result = [pscustomobject]@{
        PackageName     = $PackageName
        Manufacturer    = $metadata.Manufacturer
        Product         = $metadata.Product
        Version         = $metadata.Version
        InstallerType   = $metadata.InstallerType
        SilentArguments = $metadata.SilentArguments
        ContentPath     = $contentPath
        InstallScript   = $scripts.InstallScript
        UninstallScript = $scripts.UninstallScript
        PackageId       = $null
    }

    if (-not $PSCmdlet.ShouldProcess($PackageName, 'Create Configuration Manager package')) {
        return $result
    }

    $location = Get-Location
    try {
        $drive = Connect-SCCMPackageSite -SiteCode $config.SiteCode -SiteServer $config.SiteServer
        Set-Location $drive

        $package = New-CMPackage -Name $PackageName -Manufacturer $metadata.Manufacturer `
            -Version $metadata.Version -Path $contentPath -Description "Created by the SCCMPackage module."
        $result.PackageId = $package.PackageID
        Write-SCCMPackageLog -Message "Created package $($package.PackageID) ($PackageName)."

        $programDefaults = @{
            PackageName              = $PackageName
            StandardProgram          = $true
            RunType                  = if ($config.Program.RunType) { $config.Program.RunType } else { 'Hidden' }
            ProgramRunType           = if ($config.Program.ProgramRunType) { $config.Program.ProgramRunType } else { 'WhetherOrNotUserIsLoggedOn' }
            DiskSpaceRequirement     = $config.Program.DiskSpaceMB
            DiskSpaceUnit            = 'MB'
            Duration                 = $config.Program.DurationMinutes
        }

        New-CMProgram @programDefaults -ProgramName 'Install' -CommandLine 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install.ps1' | Out-Null
        New-CMProgram @programDefaults -ProgramName 'Uninstall' -CommandLine 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Uninstall.ps1' | Out-Null
        Write-SCCMPackageLog -Message "Created the Install and Uninstall programs for $PackageName."

        if (-not $SkipDistribution -and $config.DistributionPointGroup) {
            Start-CMContentDistribution -PackageId $package.PackageID -DistributionPointGroupName $config.DistributionPointGroup
            Write-SCCMPackageLog -Message "Distributed $($package.PackageID) to '$($config.DistributionPointGroup)'."
        }
    }
    finally {
        Set-Location $location
    }

    $result
}

Export-ModuleMember -Function @(
    'New-SCCMPackage',
    'New-SCCMPackageScript',
    'Get-SCCMPackageConfig',
    'Get-SCCMPackageInstaller',
    'Get-SCCMPackageMetadata',
    'Get-SCCMPackageMsiProperty',
    'Get-SCCMPackageSilentArgument',
    'Connect-SCCMPackageSite',
    'Set-SCCMPackageLogPath',
    'Write-SCCMPackageLog'
)
