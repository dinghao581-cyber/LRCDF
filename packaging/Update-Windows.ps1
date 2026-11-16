param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Rollback')][string]$Mode,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$WaitForPid,
    [string]$Stage
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$updateFolder = Join-Path $root '.update'
$previous = Join-Path $root '.previous'
$launcher = Join-Path $root 'project\app\windows\LRCDF.exe'
$buildPath = Join-Path $root '.update_build.json'
$componentsPath = Join-Path $root '.components.json'
$recordFiles = '.update_build.json', '.components.json'
$physical = @{
    'project' = 'project'
    'project/runs' = 'project\runs'
    'models' = 'models'
    'legacy' = 'legacy'
    'python' = 'python'
    'app' = 'project\app\windows'
}
$journal = [Collections.Generic.List[object]]::new()
$failureReason = 'apply_failed'
$guard = $null
$transaction = $null
$plugWork = $null
$desktopStopped = $false
$committed = $false
$leaveForRecovery = $false
$discardStage = $false

function Write-Json($Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 12), $utf8)
}

function Child-Path($Parent, $Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw 'Expected a path under its configured folder.'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $Parent $Relative))
    if (!$candidate.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The update path leaves its configured folder.'
    }
    return $candidate
}

function Ensure-Folder($Path) {
    [void][IO.Directory]::CreateDirectory($Path)
}

function Move-Tracked($Source, $Destination) {
    Ensure-Folder (Split-Path -Parent $Destination)
    $isDirectory = [IO.Directory]::Exists($Source)
    if ($isDirectory) {
        [IO.Directory]::Move($Source, $Destination)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
    $journal.Add([pscustomobject]@{ Source = $Source; Destination = $Destination; Directory = $isDirectory })
}

function Undo-Moves {
    for ($i = $journal.Count - 1; $i -ge 0; $i--) {
        $move = $journal[$i]
        Ensure-Folder (Split-Path -Parent $move.Source)
        if ($move.Directory) {
            [IO.Directory]::Move($move.Destination, $move.Source)
        } else {
            [IO.File]::Move($move.Destination, $move.Source)
        }
    }
}

function Remove-OwnFolder($Path, $ExpectedParent) {
    if (!$Path -or !(Test-Path -LiteralPath $Path -PathType Container)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ((Split-Path -Parent $resolved) -ine $ExpectedParent -or $resolved -ine $Path) {
        throw 'Will not remove a folder outside the intended update area.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Read-Targets($Targets, $SourceRoot, [bool]$Rollback) {
    $seen = @()
    foreach ($item in $Targets) {
        $target = [string]$item.target
        if ($target -cnotin $physical.Keys -or $target -cin $seen) { throw 'Invalid update target.' }
        $seen += $target
        $installPath = Child-Path $root $physical[$target]
        $backupName = $target.Replace('/', '-')
        # The shared project does not own either of these Windows installation trees.
        $keeps = @($item.keep | Where-Object { $_ })
        if ($target -ceq 'project') { $keeps += 'project/app/windows', 'project/runs' }
        $keeps = @($keeps | Sort-Object -Unique)
        $localKeeps = @()
        foreach ($keep in $keeps) {
            $absolute = Child-Path $root ([string]$keep)
            if (!$absolute.StartsWith($installPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'A preserved path is not inside its update target.'
            }
            $suffix = $absolute.Substring($installPath.Length + 1)
            foreach ($prior in $localKeeps) {
                if ($suffix.StartsWith($prior + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Preserved paths overlap.'
                }
            }
            $localKeeps += $suffix
        }
        $incoming = $null
        if (!$Rollback) {
            $incoming = Child-Path $SourceRoot ([string]$item.source)
            if (!$incoming.StartsWith((Join-Path $SourceRoot 'files') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The staged update tree is outside the extracted files folder.'
            }
        } elseif ($item.present -eq $true) {
            $incoming = Join-Path (Join-Path $SourceRoot 'trees') $backupName
        }
        if ($incoming -and ![IO.Directory]::Exists($incoming)) { throw 'A required update tree is missing.' }
        foreach ($keep in $localKeeps) {
            if ($incoming -and (Test-Path -LiteralPath (Join-Path $incoming $keep))) {
                throw 'The replacement tree includes a path owned by another component.'
            }
        }
        [pscustomobject]@{
            Target = $target
            Path = $installPath
            Incoming = $incoming
            BackupName = $backupName
            Keeps = $keeps
            LocalKeeps = $localKeeps
        }
    }
}

function Swap-Tree($Item, $Backup, $HoldFolder) {
    $held = @()
    foreach ($relative in $Item.LocalKeeps) {
        $live = Join-Path $Item.Path $relative
        if (Test-Path -LiteralPath $live) {
            if (!$Item.Incoming) { throw 'Cannot remove a target while preserving one of its children.' }
            $hold = Join-Path $HoldFolder $relative
            Move-Tracked $live $hold
            $held += [pscustomobject]@{ Live = $live; Hold = $hold }
        }
    }
    if ([IO.Directory]::Exists($Item.Path)) { Move-Tracked $Item.Path $Backup }
    if ($Item.Incoming) { Move-Tracked $Item.Incoming $Item.Path }
    foreach ($entry in $held) { Move-Tracked $entry.Hold $entry.Live }
}

function Plugin-Differs($Left, $Right) {
    $before = @(Get-ChildItem -LiteralPath $Left -File -Recurse -Force)
    $after = @(Get-ChildItem -LiteralPath $Right -File -Recurse -Force)
    if ($before.Count -ne $after.Count) { return $true }
    foreach ($old in $before) {
        $relative = $old.FullName.Substring($Left.Length + 1)
        $new = Join-Path $Right $relative
        if (![IO.File]::Exists($new) -or $old.Length -ne ([IO.FileInfo]::new($new)).Length) {
            return $true
        }
        $leftBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($old.FullName))
        $rightBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($new))
        if ($leftBytes -cne $rightBytes) { return $true }
    }
    return $false
}

function Set-Result([bool]$Ok, [bool]$RestartLightroom, [string]$Reason) {
    Write-Json (Join-Path $root '.update_result.json') @{
        ok = $Ok
        mode = $Mode
        restart_lightroom = $RestartLightroom
        reason = $Reason
    }
}

function Start-Desktop {
    $process = Start-Process -FilePath $launcher -WorkingDirectory (Split-Path -Parent $launcher) -WindowStyle Normal -PassThru
    try {
        if ($process.WaitForExit(5000) -and $process.ExitCode -ne 0) {
            throw 'The desktop launcher could not start the application.'
        }
    } finally {
        $process.Dispose()
    }
}

if (![IO.Directory]::Exists($root) -or (Test-Path -LiteralPath (Join-Path $root 'project\.git'))) {
    exit 1
}
Ensure-Folder $updateFolder
try {
    $guard = [IO.File]::Open((Join-Path $updateFolder 'installing'), [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
    exit 1
}

try {
    $desktop = Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue
    if ($desktop) { $desktop | Wait-Process -Timeout 90 -ErrorAction Stop }
    $desktopStopped = $true
    $originalBuild = Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json
    if ($originalBuild.platform -cnotin @('win-x64-cpu', 'win-x64-cu124') -or ![IO.File]::Exists($componentsPath)) {
        throw 'The Windows installation record is missing or invalid.'
    }

    $transaction = Join-Path $updateFolder ('swap-' + [guid]::NewGuid().ToString('N'))
    $snapshot = Join-Path $transaction 'previous-next'
    Ensure-Folder $snapshot
    $rollback = $Mode -eq 'Rollback'
    $plan = $null
    $stagePath = $null
    if ($rollback) {
        $plan = Get-Content -Raw -LiteralPath (Join-Path $previous 'rollback.json') | ConvertFrom-Json
        $previousBuild = Get-Content -Raw -LiteralPath (Join-Path $previous '.update_build.json') | ConvertFrom-Json
        if ($previousBuild.platform -cne $originalBuild.platform) { throw 'The recorded platforms do not match.' }
        $entries = @(Read-Targets $plan.targets $previous $true)
        $pieceBackup = Join-Path $transaction 'replaced'
    } else {
        if (!$Stage) { throw 'No staged update was supplied.' }
        $stagePath = [IO.Path]::GetFullPath($Stage).TrimEnd('\')
        if ((Split-Path -Parent $stagePath) -ine $updateFolder -or ![IO.File]::Exists((Join-Path $stagePath 'READY'))) {
            throw 'The staged update is incomplete.'
        }
        $plan = Get-Content -Raw -LiteralPath (Join-Path $stagePath 'plan.json') | ConvertFrom-Json
        if ($plan.version -cne (Split-Path -Leaf $stagePath) -or $plan.platform -cne $originalBuild.platform) {
            throw 'The staged version or platform is inconsistent.'
        }
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        $published = [DateTimeOffset]::Parse([string]$plan.published, $invariant)
        $seenPath = Join-Path $root '.update_seen'
        if ([IO.File]::Exists($seenPath)) {
            $seen = [DateTimeOffset]::Parse([IO.File]::ReadAllText($seenPath).Trim(), $invariant)
            if ($published -lt $seen) {
                $failureReason = 'stale_plan'
                $discardStage = $true
                throw 'A newer signed manifest was seen after this update was staged.'
            }
        }
        $entries = @(Read-Targets $plan.targets $stagePath $false)
        $pieceBackup = Join-Path $snapshot 'trees'
    }
    # Parent first in either direction, so a nested target swaps independently of a
    # kept child temporarily moved around its parent.
    $entries = @($entries | Sort-Object { ($_.Path -split '\\').Count })
    if (!$entries.Count) { throw 'No installation targets were provided.' }

    $standard = Join-Path $env:USERPROFILE 'LRCDF'
    # A native Lightroom plug-in command can still be exporting after the
    # desktop has quit. It also uses the shared code, models and runtime.
    if ($root -ieq $standard -and ($entries | Where-Object Target -ne 'app') -and
        (Get-Process -Name Lightroom -ErrorAction SilentlyContinue)) {
        $failureReason = 'lightroom_open'
        throw 'Close Lightroom Classic before replacing shared components.'
    }
    $plugPath = Join-Path $env:APPDATA 'Adobe\Lightroom\Modules\LRCDFAuto.lrplugin'
    $projectEntry = $entries | Where-Object Target -eq 'project'
    if ($projectEntry -and $root -ieq $standard -and [IO.Directory]::Exists($plugPath)) {
        if (!$rollback) {
            $plugSource = Join-Path $projectEntry.Incoming 'plugin\LRCDFAuto.lrplugin'
        } elseif ($plan.plugin) {
            $plugSource = Join-Path $previous 'plugin'
        } else {
            $plugSource = $null
        }
        if ($plugSource -and ![IO.Directory]::Exists($plugSource)) {
            throw 'The replacement Lightroom plug-in is missing from the shared code.'
        }
        try {
            if ($plugSource -and (Plugin-Differs $plugPath $plugSource)) {
                $plugWork = Join-Path (Split-Path -Parent $plugPath) ('.lrcdf-update-' + [guid]::NewGuid().ToString('N'))
                Ensure-Folder $plugWork
                Copy-Item -LiteralPath $plugSource -Destination (Join-Path $plugWork 'incoming') -Recurse
                if (!$rollback) { Copy-Item -LiteralPath $plugPath -Destination (Join-Path $snapshot 'plugin') -Recurse }
            }
        } catch [IO.IOException] {
            if (Get-Process -Name Lightroom -ErrorAction SilentlyContinue) { $failureReason = 'lightroom_open' }
            throw
        }
    }

    $originalTrees = @()
    foreach ($entry in $entries) {
        $originalTrees += @{
            target = $entry.Target
            keep = $entry.Keeps
            present = [IO.Directory]::Exists($entry.Path)
        }
        try {
            Swap-Tree $entry (Join-Path $pieceBackup $entry.BackupName) (Join-Path (Join-Path $transaction 'keep') $entry.BackupName)
        } catch {
            if ($entry.Target -ceq 'python') {
                $runtime = $entry.Path + '\'
                $workers = Get-Process -Name python,pythonw -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -and $_.Path.StartsWith($runtime, [StringComparison]::OrdinalIgnoreCase) }
                if ($workers) { $failureReason = 'runtime_busy' }
            }
            throw
        }
    }
    if ($plugWork) {
        try {
            Move-Tracked $plugPath (Join-Path $plugWork 'replaced')
            Move-Tracked (Join-Path $plugWork 'incoming') $plugPath
        } catch {
            if (Get-Process -Name Lightroom -ErrorAction SilentlyContinue) { $failureReason = 'lightroom_open' }
            throw
        }
    }

    if (!$rollback) {
        Write-Json (Join-Path $transaction 'build.json') @{ version = $plan.version; platform = $plan.platform }
        Write-Json (Join-Path $transaction 'components.json') $plan.components
        Move-Tracked $buildPath (Join-Path $snapshot '.update_build.json')
        Move-Tracked $componentsPath (Join-Path $snapshot '.components.json')
        Move-Tracked (Join-Path $transaction 'build.json') $buildPath
        Move-Tracked (Join-Path $transaction 'components.json') $componentsPath
        Write-Json (Join-Path $snapshot 'rollback.json') @{
            targets = $originalTrees
            plugin = [bool]$plugWork
            restart_lightroom = [bool]$plan.restart_lightroom
        }
        if ([IO.Directory]::Exists($previous)) { Move-Tracked $previous (Join-Path $transaction 'expired') }
        Move-Tracked $snapshot $previous
    } else {
        foreach ($name in $recordFiles) {
            Move-Tracked (Join-Path $root $name) (Join-Path $transaction $name)
            Move-Tracked (Join-Path $previous $name) (Join-Path $root $name)
        }
        Move-Tracked $previous (Join-Path $transaction 'expired')
    }

    if (![IO.File]::Exists($launcher)) { throw 'The resulting installation has no desktop launcher.' }
    Set-Result $true ([bool]$plan.restart_lightroom) ''
    $guard.Dispose()
    $guard = $null
    Start-Desktop
    $committed = $true
} catch {
    try {
        if (!$guard) {
            $guard = [IO.File]::Open((Join-Path $updateFolder 'installing'), [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        Undo-Moves
    } catch {
        # Keep the backup trees accessible if Windows also refused the reversal.
        $leaveForRecovery = $true
    }

    try {
        Set-Result $false $false $failureReason
    } finally {
        if ($guard) { $guard.Dispose(); $guard = $null }
        if ($desktopStopped -and [IO.File]::Exists($launcher)) {
            try { Start-Desktop } catch { }
        }
    }
} finally {
    if ($guard) { $guard.Dispose() }
    if (!$leaveForRecovery) {
        try {
            Remove-OwnFolder $transaction $updateFolder
            if ($plugWork) { Remove-OwnFolder $plugWork (Split-Path -Parent $plugPath) }
            if (($committed -or $discardStage) -and $stagePath) { Remove-OwnFolder $stagePath $updateFolder }
        } catch { }
    }
}

if (!$committed) { exit 1 }
