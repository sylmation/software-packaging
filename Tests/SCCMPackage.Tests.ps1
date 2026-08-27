#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'SCCMPackage\SCCMPackage.psd1') -Force

    $script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("SCCMPackageTests-" + [guid]::NewGuid())
    New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module SCCMPackage -Force -ErrorAction SilentlyContinue
}

Describe 'Get-SCCMPackageConfig' {
    It 'reads the configuration shipped with the repository' {
        $config = Get-SCCMPackageConfig
        $config.SiteCode | Should -Not -BeNullOrEmpty
        $config.SiteServer | Should -Not -BeNullOrEmpty
        $config.PackageSourceRoot | Should -Not -BeNullOrEmpty
    }

    It 'throws when a required value is missing' {
        $path = Join-Path $script:WorkRoot 'incomplete.json'
        '{ "SiteCode": "PS1" }' | Set-Content -LiteralPath $path
        { Get-SCCMPackageConfig -Path $path } | Should -Throw '*SiteServer*'
    }

    It 'throws when the file does not exist' {
        { Get-SCCMPackageConfig -Path (Join-Path $script:WorkRoot 'missing.json') } | Should -Throw '*was not found*'
    }
}

Describe 'Get-SCCMPackageInstaller' {
    BeforeAll {
        $script:SourceFolder = Join-Path $script:WorkRoot 'source'
        New-Item -Path $script:SourceFolder -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceFolder 'setup.exe') -Value 'binary'
        Set-Content -LiteralPath (Join-Path $script:SourceFolder 'readme.txt') -Value 'notes'
    }

    It 'returns the only installer in a folder' {
        (Get-SCCMPackageInstaller -SourcePath $script:SourceFolder).Name | Should -Be 'setup.exe'
    }

    It 'accepts an installer path directly' {
        $path = Join-Path $script:SourceFolder 'setup.exe'
        (Get-SCCMPackageInstaller -SourcePath $path).FullName | Should -Be $path
    }

    It 'rejects a file that is not an installer' {
        $path = Join-Path $script:SourceFolder 'readme.txt'
        { Get-SCCMPackageInstaller -SourcePath $path } | Should -Throw '*not an .msi or .exe*'
    }

    It 'throws when more than one installer is present' {
        $folder = Join-Path $script:WorkRoot 'two-installers'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'a.exe') -Value 'binary'
        Set-Content -LiteralPath (Join-Path $folder 'b.msi') -Value 'binary'
        { Get-SCCMPackageInstaller -SourcePath $folder } | Should -Throw '*More than one installer*'
    }
}

Describe 'Get-SCCMPackageSilentArgument' {
    It 'uses /qn for an MSI without reading the file' {
        $result = Get-SCCMPackageSilentArgument -Path (Join-Path $script:WorkRoot 'never-created.msi')
        $result.InstallerTechnology | Should -Be 'MSI'
        $result.SilentArguments | Should -Be '/qn /norestart'
    }

    It 'detects Inno Setup from the strings in the binary' {
        $path = Join-Path $script:WorkRoot 'inno.exe'
        Set-Content -LiteralPath $path -Value 'padding Inno Setup padding' -Encoding Ascii
        (Get-SCCMPackageSilentArgument -Path $path).SilentArguments | Should -Be '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    }

    It 'detects NSIS from the strings in the binary' {
        $path = Join-Path $script:WorkRoot 'nsis.exe'
        Set-Content -LiteralPath $path -Value 'padding Nullsoft.NSIS.exehead padding' -Encoding Ascii
        (Get-SCCMPackageSilentArgument -Path $path).SilentArguments | Should -Be '/S'
    }

    It 'reports Unknown when nothing matches' {
        $path = Join-Path $script:WorkRoot 'mystery.exe'
        Set-Content -LiteralPath $path -Value 'nothing useful here' -Encoding Ascii
        $result = Get-SCCMPackageSilentArgument -Path $path
        $result.InstallerTechnology | Should -Be 'Unknown'
        $result.SilentArguments | Should -BeNullOrEmpty
    }
}

Describe 'Get-SCCMPackageMetadata' {
    It 'falls back to the file name and a default version for an unversioned exe' {
        $folder = Join-Path $script:WorkRoot 'metadata'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'ExampleApp.exe') -Value 'padding Inno Setup padding' -Encoding Ascii

        $metadata = Get-SCCMPackageMetadata -SourcePath $folder
        $metadata.InstallerType | Should -Be 'EXE'
        $metadata.Product | Should -Be 'ExampleApp'
        $metadata.Version | Should -Be '1.0.0'
        $metadata.Manufacturer | Should -Be 'Unknown'
        $metadata.SilentArguments | Should -Be '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    }

    It 'prefers the values passed by the caller' {
        $folder = Join-Path $script:WorkRoot 'metadata-override'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'ExampleApp.exe') -Value 'binary' -Encoding Ascii

        $metadata = Get-SCCMPackageMetadata -SourcePath $folder -Manufacturer 'Contoso' -Product 'Widget' -Version '2.3.4' -SilentArguments '/quiet'
        $metadata.Manufacturer | Should -Be 'Contoso'
        $metadata.Product | Should -Be 'Widget'
        $metadata.Version | Should -Be '2.3.4'
        $metadata.SilentArguments | Should -Be '/quiet'
    }
}

Describe 'New-SCCMPackageScript' {
    BeforeAll {
        $script:Metadata = [pscustomobject]@{
            InstallerPath            = 'C:\Sources\Widget\Widget.msi'
            InstallerFile            = 'Widget.msi'
            SourceDirectory          = 'C:\Sources\Widget'
            InstallerType            = 'MSI'
            InstallerTechnology      = 'MSI'
            Manufacturer             = 'Contoso'
            Product                  = 'Widget'
            Version                  = '2.3.4'
            ProductCode              = '{11111111-2222-3333-4444-555555555555}'
            SilentArguments          = '/qn /norestart'
            SilentUninstallArguments = '/qn /norestart'
        }

        $script:ScriptFolder = Join-Path $script:WorkRoot 'scripts'
        $script:Generated = New-SCCMPackageScript -Metadata $script:Metadata -Destination $script:ScriptFolder -LogPath 'C:\Windows\Logs\SCCMPackage'
    }

    It 'writes both wrapper scripts' {
        Test-Path -LiteralPath $script:Generated.InstallScript | Should -BeTrue
        Test-Path -LiteralPath $script:Generated.UninstallScript | Should -BeTrue
    }

    It 'replaces every token' {
        foreach ($file in $script:Generated.InstallScript, $script:Generated.UninstallScript) {
            (Get-Content -LiteralPath $file -Raw) | Should -Not -Match '\{\{\w+\}\}'
        }
    }

    It 'produces scripts that parse' {
        foreach ($file in $script:Generated.InstallScript, $script:Generated.UninstallScript) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty
        }
    }

    It 'uses the product code in the uninstall script' {
        (Get-Content -LiteralPath $script:Generated.UninstallScript -Raw) | Should -BeLike '*11111111-2222-3333-4444-555555555555*'
    }
}

Describe 'Module surface' {
    It 'exports every function listed in the manifest' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:RepoRoot 'SCCMPackage\SCCMPackage.psd1')
        $exported = (Get-Module SCCMPackage).ExportedFunctions.Keys
        foreach ($name in $manifest.FunctionsToExport) {
            $exported | Should -Contain $name
        }
    }
}
