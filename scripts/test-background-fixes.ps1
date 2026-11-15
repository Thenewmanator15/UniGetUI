# Downloads, builds and runs the UniGetUI build with the background memory fixes, then records
# its memory every 30 seconds so the numbers can be compared with the installed version.
#
# Run it from a PowerShell window with:
#   irm https://raw.githubusercontent.com/Thenewmanator15/UniGetUI/windows-test/scripts/test-background-fixes.ps1 | iex
#
# Everything it creates lives in one folder (UniGetUI-test in your user folder); delete that
# folder to remove it. It installs Git and the .NET 10 SDK through winget if they are missing.

# Not 'Stop': Windows PowerShell turns anything a program writes to its error stream into an
# error, and git and dotnet both write ordinary progress there. Each step checks its own result.
$ErrorActionPreference = 'Continue'

$Branch = 'fix/pause-page-work-in-background'
$RepoUrl = 'https://github.com/Thenewmanator15/UniGetUI.git'
$Root = Join-Path $env:USERPROFILE 'UniGetUI-test'
$Repo = Join-Path $Root 'UniGetUI'
$BuildLog = Join-Path $Root 'build.log'
$MemoryLog = Join-Path $Root 'memory.csv'
$Solution = Join-Path $Repo 'src\UniGetUI.Windows.slnx'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Stop-WithMessage([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Red
    Write-Host 'Nothing else was changed. Copy the text above and send it back.' -ForegroundColor Red
    throw 'Stopped.'
}

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# global.json asks for SDK 10.0.403 and accepts any newer 10.0 feature release.
function Test-DotNet10Sdk {
    if (-not (Test-Command 'dotnet')) { return $false }
    $sdks = & dotnet --list-sdks
    foreach ($line in $sdks) {
        if ($line -match '^10\.0\.(\d+)') {
            if ([int]$Matches[1] -ge 403) { return $true }
        }
    }
    return $false
}

function Install-WithWinget([string]$Id, [string]$Name) {
    if (-not (Test-Command 'winget')) {
        Stop-WithMessage "$Name is missing and winget is not available to install it. Install $Name by hand, then run this script again."
    }
    Write-Host "Installing $Name (Windows may ask for permission)..."
    & winget install --id $Id --exact --accept-source-agreements --accept-package-agreements
    Update-PathFromRegistry
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null

# --- 1. Tools -------------------------------------------------------------------------------
Write-Step 'Step 1 of 5: checking Git and the .NET 10 SDK'

if (-not (Test-Command 'git')) {
    Install-WithWinget 'Git.Git' 'Git'
    if (-not (Test-Command 'git')) {
        Stop-WithMessage 'Git was installed but this window cannot see it yet. Close this window, open a new one and run the script again.'
    }
}
Write-Host ('Git: ' + (& git --version))

if (-not (Test-DotNet10Sdk)) {
    Install-WithWinget 'Microsoft.DotNet.SDK.10' '.NET 10 SDK'
    if (-not (Test-DotNet10Sdk)) {
        Stop-WithMessage 'The .NET 10 SDK was installed but this window cannot see it yet. Close this window, open a new one and run the script again.'
    }
}
Write-Host ('.NET SDKs: ' + ((& dotnet --list-sdks) -join ', '))

# --- 2. Code --------------------------------------------------------------------------------
Write-Step 'Step 2 of 5: downloading the code'

if (Test-Path (Join-Path $Repo '.git')) {
    Write-Host "Updating the copy in $Repo"
    & git -C $Repo fetch origin $Branch
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage 'Could not download the latest code (git fetch failed).' }
    & git -C $Repo checkout $Branch
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage 'Could not switch to the test branch (git checkout failed).' }
    & git -C $Repo merge --ff-only "origin/$Branch"
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Could not update $Repo. Delete the folder $Root and run the script again." }
}
else {
    & git clone --branch $Branch $RepoUrl $Repo
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage 'Could not download the code (git clone failed).' }
}
Write-Host ('Code version: ' + (& git -C $Repo log --oneline -1))

# --- 3. Build -------------------------------------------------------------------------------
Write-Step 'Step 3 of 5: building (several minutes the first time)'
Write-Host "Full build output goes to $BuildLog"

& cmd.exe /c "dotnet build `"$Solution`" /p:Platform=x64 --nologo -v minimal > `"$BuildLog`" 2>&1"
$buildExit = $LASTEXITCODE

if ($buildExit -ne 0) {
    Write-Host ''
    Write-Host 'THE BUILD FAILED. These are the errors:' -ForegroundColor Red
    $errors = Select-String -Path $BuildLog -Pattern ': error ' | ForEach-Object { $_.Line } | Sort-Object -Unique
    if ($errors) {
        $errors | Select-Object -First 30 | ForEach-Object { Write-Host $_ }
    }
    else {
        Get-Content $BuildLog -Tail 30 | ForEach-Object { Write-Host $_ }
    }
    Stop-WithMessage "The complete log is in $BuildLog"
}
Write-Host 'Build succeeded.' -ForegroundColor Green

# --- 4. Make sure the installed UniGetUI is not running ------------------------------------
Write-Step 'Step 4 of 5: checking for a running UniGetUI'

function Get-OtherUniGetUI {
    return Get-Process -Name 'UniGetUI' -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Path -and $_.Path.StartsWith($Repo, [StringComparison]::OrdinalIgnoreCase)) }
}

while (Get-OtherUniGetUI) {
    Write-Host 'Your installed UniGetUI is running. Quit it first: right-click its icon near the clock and choose Quit.' -ForegroundColor Yellow
    Read-Host 'Press Enter once you have quit it' | Out-Null
}
Write-Host 'No other UniGetUI is running.'

# --- 5. Run and record memory ---------------------------------------------------------------
Write-Step 'Step 5 of 5: starting the test build'

$binFolder = Join-Path $Repo 'src\UniGetUI.Avalonia\bin'
$exe = Get-ChildItem -Path $binFolder -Recurse -Filter 'UniGetUI.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $exe) {
    Stop-WithMessage "The build succeeded but UniGetUI.exe was not found under $binFolder"
}
Write-Host ('Starting ' + $exe.FullName)

$target = Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
Start-Sleep -Seconds 5

if (-not $target -or $target.HasExited) {
    Stop-WithMessage ('The test build closed straight away. Try starting it by hand: ' + $exe.FullName)
}

Write-Host 'The test UniGetUI is running.' -ForegroundColor Green
Write-Host ''
Write-Host 'Things to try (watch Task Manager, Ctrl+Shift+Esc, as well):'
Write-Host '  1. Close the window so it goes to the tray and wait 30 seconds: memory should drop,'
Write-Host '     and a green leaf should appear next to UniGetUI in Task Manager.'
Write-Host '  2. Leave it in the tray for a while: memory should stay level instead of climbing.'
Write-Host '  3. Reopen the window: the green leaf should disappear.'
Write-Host '  4. Open the Help page, then close to the tray: the WebView2 entries should go away.'
Write-Host '  5. Search on Discover and install something: it should work as normal.'
Write-Host ''
Write-Host "Memory is recorded every 30 seconds below and in $MemoryLog"
Write-Host 'To finish, quit the test UniGetUI from its tray icon (or press Ctrl+C here).'
Write-Host ''

'Time,PrivateMB,WorkingSetMB,CpuSeconds,Threads,WebView2Processes' | Set-Content -Path $MemoryLog -Encoding UTF8
Write-Host ('{0,-10} {1,10} {2,13} {3,11} {4,8} {5,9}' -f 'Time', 'PrivateMB', 'WorkingSetMB', 'CpuSeconds', 'Threads', 'WebView2')

$targetId = $target.Id
while ($true) {
    $p = Get-Process -Id $targetId -ErrorAction SilentlyContinue
    if (-not $p) { break }

    $webViews = 0
    try {
        $webViews = @(Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf('UniGetUI', [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
    }
    catch { $webViews = -1 }

    $time = Get-Date -Format 'HH:mm:ss'
    $private = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
    $working = [math]::Round($p.WorkingSet64 / 1MB, 1)
    $cpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1)
    $threads = $p.Threads.Count

    "$time,$private,$working,$cpu,$threads,$webViews" | Add-Content -Path $MemoryLog -Encoding UTF8
    Write-Host ('{0,-10} {1,10} {2,13} {3,11} {4,8} {5,9}' -f $time, $private, $working, $cpu, $threads, $webViews)

    Start-Sleep -Seconds 30
}

Write-Host ''
Write-Host 'The test UniGetUI has closed.' -ForegroundColor Cyan
Write-Host "The memory readings are in $MemoryLog - send that file (or the table above) back."
Write-Host 'You can start your normal UniGetUI again now.'
