@{
    RootModule        = 'SCCMPackage.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '79f382c8-a411-4ade-b50c-c462b2373dad'
    Author            = 'sylmation'
    CompanyName       = 'sylmation'
    Description       = 'CLI driven creation of Configuration Manager packages (packaging mode) for .msi and .exe installers, with generated install and uninstall scripts.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('SCCM', 'ConfigMgr', 'MECM', 'Packaging')
        }
    }
}
