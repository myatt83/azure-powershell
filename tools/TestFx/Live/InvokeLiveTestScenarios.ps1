param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RunPlatform,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RunPowerShell,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PowerShellLatest,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $RepoLocation,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataLocation
)

if ($RunPowerShell -eq "latest") {
    $curPSVer = (Get-Variable -Name PSVersionTable -ValueOnly).PSVersion
    $curMajorVer = $curPSVer.Major
    $curMinorVer = $curPSVer.Minor
    $curSimpleVer = "$curMajorVer.$curMinorVer"
    if ($curSimpleVer -eq $PowerShellLatest) {
        Write-Host "##[section]Skipping live tests for PowerShell $curSimpleVer as it has already been explicitly specified in the pipeline." -ForegroundColor Green
        return
    }
}

$srcDir = Join-Path -Path $RepoLocation -ChildPath "src"
$liveScenarios = Get-ChildItem -Path $srcDir -Directory -Exclude "Accounts" | Get-ChildItem -Directory -Filter "LiveTests" -Recurse | Get-ChildItem -File -Filter "TestLiveScenarios.ps1" | Select-Object -ExpandProperty FullName

$rsp = [runspacefactory]::CreateRunspacePool(1, [int]$env:NUMBER_OF_PROCESSORS + 1)
[void]$rsp.Open()

$liveJobs = $liveScenarios | ForEach-Object {
    $module = [regex]::match($_, "[\\|\/]src[\\|\/](?<ModuleName>[a-zA-Z]+)[\\|\/]").Groups["ModuleName"].Value

    $ps = [powershell]::Create()
    $ps.RunspacePool = $rsp
    [void]$ps.AddScript({
        param (
            [string] $Module,
            [string] $RunPlatform,
            [string] $PowerShellLatest,
            [string] $DataLocation,
            [string] $LiveScenarioScript
        )

        Write-Output "##[section]Live test run for module `"$Module`""

        Import-Module "./tools/TestFx/Assert.ps1" -Force
        Import-Module "./tools/TestFx/Live/LiveTestUtility.psd1" -ArgumentList $Module, $RunPlatform, $PowerShellLatest, $DataLocation -Force
        . $LiveScenarioScript

        Write-Output ""

    }).AddParameter("Module", $module).AddParameter("RunPlatform", $RunPlatform).AddParameter("PowerShellLatest", $PowerShellLatest).AddParameter("DataLocation", $DataLocation).AddParameter("LiveScenarioScript", $_)

    [PSCustomObject]@{
        Id          = $ps.InstanceId
        Name        = $module
        Instance    = $ps
        AsyncHandle = $ps.BeginInvoke()
    } | Add-Member State -MemberType ScriptProperty -Value {
        $bFlags = "NonPublic", "Instance", "Static"
        $worker = $this.Instance.GetType().GetField("_worker", $bFlags).GetValue($this.Instance)
        $crp = $worker.GetType().GetProperty("CurrentlyRunningPipeline", $bFlags).GetValue($worker, $null)
        if ($this.AsyncHandle.IsCompleted -and ![bool]$crp) {
            "Completed"
        }
        elseif (!$this.AsyncHandle.IsCompleted -and [bool]$crp) {
            "Running"
        }
        elseif (!$this.AsyncHandle.IsCompleted -and ![bool]$crp) {
            "NotStarted"
        }
        else {
            "Unknown"
        }
    }
}

Start-Sleep -Seconds 300

$totalJobsCount = $liveJobs.Count
$queuedJobs = $liveJobs
while ($queuedJobs.Count -gt 0) {
    Start-Sleep -Seconds 60

    $waitingJobs = @()
    $runningJobs = @()
    $completedJobs = @()
    foreach ($job in $queuedJobs) {
        switch ($job.State) {
            "NotStarted" {
                $waitingJobs += $job
            }
            "Running" {
                $runningJobs += $job
            }
            "Completed" {
                $completedJobs += $job
            }
        }
    }

    $completedJobsCount += $completedJobs.Count
    if ($completedJobs.Count -gt 0) {
        $completedJobs | ForEach-Object {
            if ($null -ne $_.Instance) {
                $_.Instance.EndInvoke($_.AsyncHandle)
                $_.Instance.Streams | Select-Object -Property @{ Name = "FullOutput"; Expression = { $_.Debug, $_.Error } } | Select-Object -ExpandProperty FullOutput
                $_.Instance.Dispose()
            }
        }
    }

    $queuedJobs = $waitingJobs + $runningJobs

    Write-Host "##[group]Progress of the live test jobs" -ForegroundColor Magenta

    Write-Host "##[section]Total jobs: $totalJobsCount" -ForegroundColor Green
    Write-Host "##[section]Waiting jobs: $($waitingJobs.Count)" -ForegroundColor Green
    Write-Host "##[section]Running jobs: $($runningJobs.Count)" -ForegroundColor Green
    Write-Host "##[section]Completed jobs: $completedJobsCount" -ForegroundColor Green
    Write-Host "##[section]Available runspaces in the pool: $($rsp.AvailableRunspaces)" -ForegroundColor Green

    $queuedJobs | Select-Object Id, Name, State

    Write-Host "##[endgroup]" -ForegroundColor Magenta
}

$rsp.Dispose()

$accountsDir = Join-Path -Path $srcDir -ChildPath "Accounts"
$accountsLiveScenario = Get-ChildItem -Path $accountsDir -Directory -Filter "LiveTests" -Recurse | Get-ChildItem -File -Filter "TestLiveScenarios.ps1" | Select-Object -ExpandProperty FullName
if ($null -ne $accountsLiveScenario) {
    Import-Module "./tools/TestFx/Assert.ps1" -Force
    Import-Module "./tools/TestFx/Live/LiveTestUtility.psd1" -ArgumentList "Accounts", $RunPlatform, $PowerShellLatest, $DataLocation -Force
    . $accountsLiveScenario
}

Write-Host "##[section]Waiting for all cleanup jobs to be completed." -ForegroundColor Green
while (Get-Job -State Running) {
    Start-Sleep -Seconds 30
}
Write-Host "##[section]All cleanup jobs are completed." -ForegroundColor Green

Write-Host "##[group]Cleanup jobs information." -ForegroundColor Magenta

Write-Host
$cleanupJobs = Get-Job
$cleanupJobs | Select-Object Name, Command, State, PSBeginTime, PSEndTime, Output
Write-Host

Write-Host "##[endgroup]" -ForegroundColor Magenta

$cleanupJobs | Remove-Job
