# Module manifest for module 'Wslcmd'
#

@{
    RootModule = 'Wslcmd.psm1'
    ModuleVersion = '1.0.0'
    # TODO: set GUID
    # GUID = ''
    Author = 'mimikun'
    CompanyName = 'mimikun.jp'
    Copyright = 'Copyright (c) 2024 mimikun'
    Description = 'Commandlets for operating WSL for mimikun'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        "Get-WslStatus",
        "Invoke-WslStart",
        "Invoke-WslReStart",
        "Invoke-WslShutdown"
    )
    FileList = @("Wslcmd.psd1", "Wslcmd.psm1")
    PrivateData = @{
        PSData = @{
            Tags = @("WSL", "Windows")
            LicenseUri = 'https://github.com/mimikun/Wslcmd/blob/main/LICENSE.txt'
            ProjectUri = 'https://github.com/mimikun/Wslcmd'
        }
    }
}
