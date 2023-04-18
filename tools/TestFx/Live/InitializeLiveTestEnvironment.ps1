param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $DesiredVersion
)

$winPSVersion = "5.1"
$isWinPSDesired = $DesiredVersion -eq $winPSVersion

function InstallLiveTestDesiredPowerShell {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DesiredVersion
    )

    Write-Host "Validating desired PowerShell version."

    if ($isWinPSDesired) {
        powershell -NoLogo -NoProfile -NonInteractive -Command "(Get-Variable -Name PSVersionTable).Value"
        Write-Host "##[section]Desired Windows Powershell version $DesiredVersion has been installed."
    }
    else {
        Write-Host "##[section]Installing PowerShell version $DesiredVersion."

        dotnet --version
        dotnet new tool-manifest --force
        if ($DesiredVersion -eq "latest") {
            dotnet tool install powershell
        }
        else {
            dotnet tool install powershell --version $DesiredVersion
        }
        dotnet tool list

        dotnet tool run pwsh -Version

        Write-Host "##[section]Desired PowerShell version $DesiredVersion has been installed."
    }
}

& (Join-Path -Path ($PSScriptRoot | Split-Path) -ChildPath "Utilities" | Join-Path -ChildPath "CommonUtility.ps1")
InstallLiveTestDesiredPowerShell -DesiredVersion $DesiredVersion
