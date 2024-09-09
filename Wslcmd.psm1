<#
# Represents the state of a distribution.
enum WslDistributionState {
    Stopped
    Running
    Installing
    Uninstalling
    Converting
}

# Represents the format of a distribution to export or import.
enum WslExportFormat {
    Auto
    Tar
    Vhd
}

# Represents a WSL distribution.
class WslDistribution
{
    WslDistribution()
    {
        $this | Add-Member -Name FileSystemPath -Type ScriptProperty -Value {
            return "\\wsl.localhost\$($this.Name)"
        }

        $defaultDisplaySet = "Name","State","Version","Default"

        #Create the default property display set
        $defaultDisplayPropertySet = New-Object System.Management.Automation.PSPropertySet("DefaultDisplayPropertySet",[string[]]$defaultDisplaySet)
        $PSStandardMembers = [System.Management.Automation.PSMemberInfo[]]@($defaultDisplayPropertySet)
        $this | Add-Member MemberSet PSStandardMembers $PSStandardMembers
    }

    [string] ToString()
    {
        return $this.Name
    }

    [string]$Name
    [WslDistributionState]$State
    [int]$Version
    [bool]$Default
    [Guid]$Guid
    [string]$BasePath
    [string]$VhdPath
}

# Provides the versions of various WSL components.
class WslVersionInfo {
    [Version]$Wsl
    [Version]$Kernel
    [Version]$WslG
    [Version]$Msrdc
    [Version]$Direct3D
    [Version]$DXCore
    [Version]$Windows
    [int]$DefaultDistroVersion
}

# Provides the details of online distributions
class WslDistributionOnline {
    [string]$Name
    [string]$FriendlyName
}

# $IsWindows can be used on PowerShell 6+ to determine if we're running on Windows or not.
# On Windows PowerShell 5.1, this variable does not exist so we assume we're running on Windows.
# N.B. We don't assign directly to $IsWindows because that causes a PSScriptAnalyzer warning, since
#      it's an automatic variable. All checks should use $IsWindowsOS instead.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $IsWindowsOS = $true

} else {
    $IsWindowsOS = $IsWindows
}

if ($IsWindowsOS) {
    $wslPath = "$env:windir\system32\wsl.exe"
    $wslgPath = "$env:windir\system32\wslg.exe"
    if (-not [System.Environment]::Is64BitProcess) {
        # Allow launching WSL from 32 bit powershell
        $wslPath = "$env:windir\sysnative\wsl.exe"
        $wslgPath = "$env:windir\sysnative\wslg.exe"
    }

} else {
    # If running inside WSL, rely on wsl.exe being in the path.
    $wslPath = "wsl.exe"
    $wslgPath = "wslg.exe"
}

function Get-UnresolvedProviderPath([string]$Path)
{
    if ($IsWindowsOS) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

    } else {
        # Don't translate on Linux, because absolute Linux paths will never work, and relative ones
        # will.
        return $Path
    }
}

# Helper that will launch wsl.exe, correctly parsing its output encoding, and throwing an error
# if it fails.
function Invoke-Wsl([string[]]$WslArgs, [Switch]$IgnoreErrors)
{
    try {
        $encoding = [System.Text.Encoding]::Unicode
        if ($IsLinux) {
            # If running inside WSL, we can't easily determine the value WSL_UTF8 had in Windows,
            # so set it explicitly. It is set to zero to ensure compatibility with older WSL
            # versions that don't support this variable.
            $originalWslUtf8 = $env:WSL_UTF8
            $originalWslEnv = $env:WSLENV
            $env:WSL_UTF8 = "0"
            $env:WSLENV += ":WSL_UTF8"

        } elseif ($env:WSL_UTF8 -eq "1") {
            $encoding = [System.Text.Encoding]::Utf8
        }

        $hasError = $false
        if ($PSVersionTable.PSVersion.Major -lt 6 -or $PSVersionTable.PSVersion.Major -ge 7) {
            try {
                $oldOutputEncoding = [System.Console]::OutputEncoding
                [System.Console]::OutputEncoding = $encoding
                $output = &$wslPath @WslArgs
                if ($LASTEXITCODE -ne 0) {
                    $hasError = $true
                }

            } finally {
                [System.Console]::OutputEncoding = $oldOutputEncoding
            }

        } else {
            # Using Console.OutputEncoding is broken on PowerShell 6, so use an alternative method of
            # starting wsl.exe.
            # See: https://github.com/PowerShell/PowerShell/issues/10789
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo $wslPath
            $WslArgs | ForEach-Object { $startInfo.ArgumentList.Add($_) }
            $startInfo.RedirectStandardOutput = $true
            $startInfo.StandardOutputEncoding = $encoding
            $process = [System.Diagnostics.Process]::Start($startInfo)
            $output = @()
            while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
                if ($line.Length -gt 0) {
                    $output += $line
                }
            }

            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                $hasError = $true
            }
        }

    } finally {
        if ($IsLinux) {
            $env:WSL_UTF8 = $originalWslUtf8
            $env:WSLENV = $originalWslEnv
        }
    }

    # $hasError is used so there's no output in case error action is silently continue.
    if ($hasError) {
        if (-not $IgnoreErrors) {
            throw "Wsl.exe failed: $output"
        }

        return @()
    }

    return $output
}

# Helper to parse the output of wsl.exe --list.
# Also used by the tab completion function.
function Get-WslDistributionHelper()
{
    Invoke-Wsl "--list","--verbose" -IgnoreErrors | Select-Object -Skip 1 | ForEach-Object {
        $fields = $_.Split(@(" "), [System.StringSplitOptions]::RemoveEmptyEntries) 
        $defaultDistro = $false
        if ($fields.Count -eq 4) {
            $defaultDistro = $true
            $fields = $fields | Select-Object -Skip 1
        }

        [WslDistribution]@{
            "Name" = $fields[0]
            "State" = $fields[1]
            "Version" = [int]$fields[2]
            "Default" = $defaultDistro
        }
    }
}

# Helper to get additional distribution properties from the registry.
function Get-WslDistributionProperties([WslDistribution]$Distribution)
{
    $key = Get-ChildItem "hkcu:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss" | Get-ItemProperty | Where-Object { $_.DistributionName -eq $Distribution.Name }
    if ($key) {
        $Distribution.Guid = $key.PSChildName
        $Distribution.BasePath = $key.BasePath
        if ($Distribution.BasePath.StartsWith("\\?\")) {
            $Distribution.BasePath = $Distribution.BasePath.Substring(4)
        }

        if ($Distribution.Version -eq 2) {
            $vhdFile = "ext4.vhdx"
            if ($key.VhdFileName) {
                $vhdFile = $key.VhdFileName
            }

            $Distribution.VhdPath = Join-Path $Distribution.BasePath $vhdFile
        }
    }
}

function Get-WslDistribution
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline = $true)]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string[]]$Name,
        [Parameter(Mandatory=$false)]
        [Switch]$Default,
        [Parameter(Mandatory=$false)]
        [WslDistributionState]$State,
        [Parameter(Mandatory=$false)]
        [int]$Version
    )

    process {
        $distributions = Get-WslDistributionHelper
        if ($Default) {
            $distributions = $distributions | Where-Object {
                $_.Default
            }
        }

        if ($PSBoundParameters.ContainsKey("State")) {
            $distributions = $distributions | Where-Object {
                $_.State -eq $State
            }
        }

        if ($PSBoundParameters.ContainsKey("Version")) {
            $distributions = $distributions | Where-Object {
                $_.Version -eq $Version
            }
        }

        if ($Name.Length -gt 0) {
            $distributions = $distributions | Where-Object {
                foreach ($pattern in $Name) {
                    if ($_.Name -ilike $pattern) {
                        return $true
                    }
                }
                
                return $false
            }
        }

        # The additional registry properties aren't available if running inside WSL.
        if ($IsWindowsOS) {
            $distributions | ForEach-Object {
                Get-WslDistributionProperties $_
            }
        }

        return $distributions
    }
}


# Retrieves listing of distributions available from online sources
function Get-WslDistributionOnline
{
    [CmdletBinding()]
    param()

    $store = $false
    Invoke-Wsl "--list", "--online" -IgnoreErrors | ForEach-Object {
        $name, $friendlyName = $_ -split ' ', 2
        if ($store) {
            $friendlyName = $friendlyName.Trim()
            [WslDistributionOnline]@{
                "Name" = $name
                "FriendlyName" = $friendlyName
            }

        } elseif ($name -ceq "NAME") {
            # The "NAME", "FRIENDLY NAME" header is not localized so can be used to find the start
            # of the list
            $store = $true
        }
    }
}

function Stop-WslDistribution
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "DistributionName", Position = 0)]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildCards()]
        [string[]]$Name,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "Distribution")]
        [WslDistribution[]]$Distribution,
        [Parameter(Mandatory = $false)]
        [Switch]$Passthru
    )

    process
    {
        if ($PSCmdlet.ParameterSetName -eq "DistributionName") {
            $distros = Get-WslDistribution $Name
            if (-not $distros) {
                throw "There is no distribution with the name '$Name'."
            }

        } else {
            $distros = $Distribution
        }

        $distros | ForEach-Object {
            if ($_.State -ne [WslDistributionState]::Running) {
                Write-Warning "Distribution $($_.Name) is not running."

            } elseif ($PSCmdlet.ShouldProcess($_.Name, "Terminate")) {
                Invoke-Wsl "--terminate",$_.Name
            }

            if ($Passthru) {
                # Re-query to get the updated state.
                Get-WslDistribution $_.Name
            }
        }
    }
}

function Set-WslDistribution
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "DistributionName", Position = 0)]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildCards()]
        [string[]]$Name,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "Distribution")]
        [WslDistribution[]]$Distribution,
        [Parameter(Mandatory = $false)]
        [int]$Version = 0,
        [Parameter(Mandatory = $false)]
        [Switch]$Default,
        [Parameter(Mandatory = $false)]
        [Switch]$Passthru
    )

    process
    {
        if ($PSCmdlet.ParameterSetName -eq "DistributionName") {
            $distros = Get-WslDistribution $Name
            if (-not $distros) {
                throw "There is no distribution with the name '$Name'."
            }

        } else {
            $distros = $Distribution
        }

        $distros | ForEach-Object {
            if ($Version -ne 0) {
                if ($_.Version -eq $Version) {
                    Write-Warning "The distribution '$($_.Name)' is already the requested version."

                } elseif ($PSCmdlet.ShouldProcess($_.Name, "Set Version")) {
                    # Suppress output since it messes with passthru
                    Invoke-Wsl "--set-version",$_.Name,$Version | Out-Null
                }
            }

            if ($Default) {
                if ($_.Default) {
                    Write-Warning "The distribution '$($_.Name)' is already the default."

                } if ($PSCmdlet.ShouldProcess($_.Name, "Set Default")) {
                    Invoke-Wsl "--set-default",$_.Name | Out-Null
                }
            }

            # Get updated info for pass-through.
            if ($Passthru) {
                Get-WslDistribution $_.Name
            }
        }
    }
}

function Remove-WslDistribution
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "DistributionName", Position = 0)]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildCards()]
        [string[]]$Name,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "Distribution")]
        [WslDistribution[]]$Distribution
    )

    process
    {
        if ($PSCmdlet.ParameterSetName -eq "DistributionName") {
            $distros = Get-WslDistribution $Name
            if ($distros.Length -eq 0) {
                throw "There is no distribution with the name '$Name'."
            }
    
        } else {
            $distros = $Distribution
        }

        $distros | ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.Name, "Unregister")) {
                Invoke-Wsl "--unregister",$_.Name | Out-Null
            }
        }
    }
}

function Export-WslDistribution
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "DistributionName", Position = 0)]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildCards()]
        [string[]]$Name,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "Distribution")]
        [WslDistribution[]]$Distribution,
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Destination,
        [Parameter(Mandatory = $false)]
        [Alias("fmt")]
        [WslExportFormat]$Format = [WslExportFormat]::Auto
    )

    process
    {
        if ($PSCmdlet.ParameterSetName -eq "DistributionName") {
            $distros = Get-WslDistribution $Name
            if (-not $distros) {
                throw "There is no distribution with the name '$Name'."
            }

        } else {
            $distros = $Distribution
        }

        $distros | ForEach-Object {
            $fullPath = $Destination
            $vhd = $false
            if (Test-Path $Destination -PathType Container) {
                if ($Format -eq [WslExportFormat]::Vhd) {
                    $extension = ".vhdx"
                    $vhd = $true

                } else {
                    $extension = ".tar.gz"
                }

                $fullPath = Join-Path $Destination "$($_.Name)$extension"

            } else {
                if ($Format -eq [WslExportFormat]::Auto) {
                    # Split-Path -Extension is not available on Windows PowerShell.
                    $extension = [System.IO.Path]::GetExtension($Destination)
                    if ($extension -ieq ".vhdx") {
                        $vhd = $true
                    }

                } else {
                    $vhd = ($Format -eq [WslExportFormat]::Vhd)
                }
            }

            if (Test-Path $fullPath) {
                throw "The path '$fullPath' already exists."
            }

            $fullPath = Get-UnresolvedProviderPath $fullPath
            if ($PSCmdlet.ShouldProcess("Distribution: $($_.Name), Path: $fullPath", "Export")) {
                $wslArgs = @("--export", $_.Name, $fullPath)
                if ($vhd) {
                    $wslArgs += "--vhd"
                }

                Invoke-Wsl $wslArgs | Out-Null
                Get-Item -LiteralPath $fullPath
            }
        }
    }
}

function Import-WslDistribution
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = "PathInPlace")]
        [Parameter(Mandatory = $true, ParameterSetName = "LiteralPathInPlace")]
        [Alias("ip")]
        [Switch]$InPlace,
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Path", ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "PathInPlace", ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string[]] $Path,
        [Parameter(Mandatory = $true, ParameterSetName = "LiteralPath", ValueFromPipelineByPropertyName = $true)]
        [Parameter(Mandatory = $true, ParameterSetName = "LiteralPathInPlace", ValueFromPipelineByPropertyName = $true)]
        [Alias("PSPath", "LP")]
        [ValidateNotNullOrEmpty()]
        [string[]] $LiteralPath,
        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = "Path")]
        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = "LiteralPath")]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,
        [Parameter(Mandatory = $false, Position = 2)]
        [Alias("DistributionName")]
        [string]$Name,
        [Parameter(Mandatory = $false, Position = 3, ParameterSetName = "Path")]
        [Parameter(Mandatory = $false, Position = 3, ParameterSetName = "LiteralPath")]
        [int]$Version = 0,
        [Parameter(Mandatory = $false, ParameterSetName = "Path")]
        [Parameter(Mandatory = $false, ParameterSetName = "LiteralPath")]
        [Alias("rd")]
        [Switch]$RawDestination,
        [Parameter(Mandatory = $false, ParameterSetName = "Path")]
        [Parameter(Mandatory = $false, ParameterSetName = "LiteralPath")]
        [Alias("fmt")]
        [WslExportFormat]$Format = [WslExportFormat]::Auto
    )

    process {
        if ($Path) {
            $files = Get-Item $Path
        } else {
            $files = Get-Item -LiteralPath $LiteralPath
        }    

        $files | ForEach-Object {
            $distributionName = $Name
            if ($distributionName -eq "") {
                $distributionName = $_.BaseName
                # If the file name is .tar.gz, the base name isn't what we want.
                if ($distributionName.EndsWith(".tar", "OrdinalIgnoreCase")) {
                    $distributionName = $distributionName.Substring(0, $distributionName.Length - 4)
                }
            }

            if ($Format -eq [WslExportFormat]::Auto) {
                $vhd = $_.Extension -ieq ".vhdx"

            } else {
                $vhd = $Format -eq [WslExportFormat]::Vhd
            }

            if ($InPlace) {
                if ($PSCmdlet.ShouldProcess("Path: $($_.FullName) (in place), Name: $distributionName", "Import")) {
                    Invoke-Wsl @("--import-in-place", $distributionName, $_.FullName) | Out-Null
                    Get-WslDistribution $DistributionName
                }
    
            } else {
                $distributionDestination = $Destination
                if (-not $RawDestination) {
                    $distributionDestination = Join-Path $distributionDestination $distributionName
                }

                $distributionDestination = Get-UnresolvedProviderPath $distributionDestination
                if ($PSCmdlet.ShouldProcess("Path: $($_.FullName), Destination: $distributionDestination, Name: $distributionName", "Import")) {
                    $wslArgs = @("--import", $distributionName, $distributionDestination, $_.FullName)
                    if ($Version -ne 0) {
                        $wslArgs += @("--version", $Version)
                    }

                    if ($vhd) {
                        $wslArgs += "--vhd"
                    }

                    Invoke-Wsl $wslArgs | Out-Null
                    Get-WslDistribution $DistributionName
                }
            }
        }
    }
}

function Invoke-WslCommand
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Distribution")]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "DistributionName")]
        [ValidateNotNullOrEmpty()]
        [string]$Command,
        [Parameter(Mandatory = $true, ParameterSetName = "DistributionNameRaw")]
        [Parameter(Mandatory = $true, ParameterSetName = "DistributionRaw")]
        [Switch]$RawCommand,
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = "DistributionName", Position = 1)]
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = "DistributionNameRaw")]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildCards()]
        [string[]]$Name,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "Distribution")]
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "DistributionRaw")]
        [WslDistribution[]]$Distribution,
        [Parameter(Mandatory = $false, Position = 2, ParameterSetName = "Distribution")]
        [Parameter(Mandatory = $false, Position = 2, ParameterSetName = "DistributionName")]
        [Parameter(Mandatory = $false, ParameterSetName = "DistributionRaw")]
        [Parameter(Mandatory = $false, ParameterSetName = "DistributionNameRaw")]
        [ValidateNotNullOrEmpty()]
        [string]$User,
        [Parameter(Mandatory = $false)]
        [Alias("wd", "cd")]
        [ValidateNotNullOrEmpty()]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $false)]
        [Alias("st")]
        [ValidateSet("Standard", "Login", "None")]
        [string]$ShellType,
        [Parameter(Mandatory = $false)]
        [Switch]$System,
        [Parameter(Mandatory = $false)]
        [Switch]$Graphical,
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true, ParameterSetName = "DistributionRaw")]
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true, ParameterSetName = "DistributionNameRaw")]
        [ValidateNotNullOrEmpty()]
        [string[]]$Remaining
    )

    process {
        if ($Distribution) {
            $distros = $Distribution

        } else {
            if ($Name) {
                $distros = Get-WslDistribution $Name
                if (-not $distros) {
                    throw "There is no distribution with the name '$Name'."
                }

            } else {
                $distros = Get-WslDistribution -Default
                if (-not $distros) {
                    throw "There is no default distribution."
                }
            }

        }

        $distros | ForEach-Object {
            $wslArgs = @("--distribution", $_.Name)
            if ($System) {
                $wslArgs += "--system"
            }

            if ($User) {
                $wslArgs += @("--user", $User)
            }

            if ($WorkingDirectory) {
                if (-not $WorkingDirectory.StartsWith("~") -and -not $WorkingDirectory.StartsWith("/")) {
                    $WorkingDirectory = Get-UnresolvedProviderPath $WorkingDirectory
                }

                $wslArgs += @("--cd", $WorkingDirectory)
            }

            if ($ShellType) {
                $wslArgs += @("--shell-type", $ShellType.ToLowerInvariant())
            }

            if ($RawCommand) {
                $wslArgs += "--"
                $wslArgs += $Remaining

            } else {
                # Invoke /bin/sh so the whole command can be passed as a single argument.
                $wslArgs += @("/bin/sh", "-c", $Command)
            }

            if ($PSCmdlet.ShouldProcess($_.Name, "Invoke Command; args: $wslArgs")) {
                if ($Graphical) {
                    &$wslgPath $wslArgs

                } else {
                    &$wslPath $wslArgs
                }
                if ($LASTEXITCODE -ne 0) {
                    # Note: this could be the exit code of wsl.exe, or of the launched command.
                    throw "Wsl.exe returned exit code $LASTEXITCODE"
                }    
            }
        }
    }
}

function Enter-WslDistribution
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = "DistributionName", Position = 0)]
        [Alias("DistributionName")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = "Distribution")]
        [WslDistribution]$Distribution,
        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$User,
        [Parameter(Mandatory = $false)]
        [Alias("wd", "cd")]
        [ValidateNotNullOrEmpty()]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $false)]
        [Alias("st")]
        [ValidateSet("Standard", "Login")]
        [string]$ShellType,
        [Parameter(Mandatory = $false)]
        [Switch]$System
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq "Distribution") {
            $Name = $Distribution.Name
        }

        $wslArgs = @()
        if ($Name) {
            $wslArgs = @("--distribution", $Name)
        }

        if ($System) {
            $wslArgs += "--system"
        }

        if ($User) {
            $wslArgs = @("--user", $User)
        }

        if ($WorkingDirectory) {
            if (-not $WorkingDirectory.StartsWith("~") -and -not $WorkingDirectory.StartsWith("/")) {
                $WorkingDirectory = Get-UnresolvedProviderPath $WorkingDirectory
            }

            $wslArgs += @("--cd", $WorkingDirectory)
        }

        if ($ShellType) {
            $wslArgs += @("--shell-type", $ShellType.ToLowerInvariant())
        }

        if ($PSCmdlet.ShouldProcess($Name, "Enter WSL; args: $wslArgs")) {
            &$wslPath $wslArgs
            if ($LASTEXITCODE -ne 0) {
                # Note: this could be the exit code of wsl.exe, or of the shell.
                throw "Wsl.exe returned exit code $LASTEXITCODE"
            }
        }
    }
}

function Stop-Wsl
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()

    if ($PSCmdlet.ShouldProcess("Wsl", "Shutdown")) {
        Invoke-Wsl "--shutdown"
    }
}

function Get-WslVersion
{
    [CmdletBinding()]
    param()

    $output = Invoke-Wsl "--version" -IgnoreErrors | ForEach-Object {
        $value = $_
        $index = $_.LastIndexOf(':')
        if ($index -ge 0) {
            $value = $_.Substring($index + 1).Trim()
        }

        $index = $value.IndexOf('-')
        if ($index -ge 0) {
            $value = $value.Substring(0, $index)
        }

        [Version]::Parse($value)
    }

    $result = [WslVersionInfo]::new()
    if ($output) {
        # This relies on the order of the items returned, which is very fragile, but unfortunately
        # the names are localized so there is no reliable way to determine which items is which.
        $result.Wsl = $output[0]
        $result.Kernel = $output[1]
        $result.WslG = $output[2]
        $result.Msrdc = $output[3]
        $result.Direct3D = $output[4]
        $result.DXCore = $output[5]
        $result.Windows = $output[6]

    }  elseif ($IsWindowsOS) {
        $result.Windows = [Environment]::OSVersion.Version
    }

    if ($IsWindowsOS) {
        # Build 20150 is when WSL2 became the default if not specified in the registry.
        if ([Environment]::OSVersion.Version -lt [Version]::new(10, 0, 20150)) {
            $result.DefaultDistroVersion = 1

        } else {
            $result.DefaultDistroVersion = 2
        }

        if (Test-Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss) {
            $props = Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss
            if ($props.DefaultVersion) {
                $result.DefaultDistroVersion = $props.DefaultVersion
            }
        }
    }

    return $result
}

$tabCompletionScript = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    (Get-WslDistributionHelper).Name | Where-Object { $_ -ilike "$wordToComplete*" } | Sort-Object
}

Register-ArgumentCompleter -CommandName Get-WslDistribution,Stop-WslDistribution,Set-WslDistribution,Remove-WslDistribution,Export-WslDistribution,Enter-WslDistribution -ParameterName Name -ScriptBlock $tabCompletionScript
Register-ArgumentCompleter -CommandName Invoke-WslCommand -ParameterName DistributionName -ScriptBlock $tabCompletionScript
#>

function Invoke-WslShutdown
{
    [CmdletBinding()]
    param(
    )

    if (Force)) {
        "wsl --shutdown"
    }
    else {
        if ($isWorkPC) {
            "wsl --terminate Ubuntu20.04"
        }
        else {
            "wsl --terminate Ubuntu"
        }
    }
}

Export-ModuleMember Get-WslStatus
Export-ModuleMember Invoke-WslStart
Export-ModuleMember Invoke-WslReStart
Export-ModuleMember Invoke-WslShutdown
