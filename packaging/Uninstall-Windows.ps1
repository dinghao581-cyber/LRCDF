$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$standardRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'LRCDF'))
if ($root.TrimEnd('\') -ne $standardRoot.TrimEnd('\')) {
    throw 'Run the uninstaller from the installed LRCDF application.'
}
if (Get-Process Lightroom -ErrorAction SilentlyContinue) {
    throw 'Close Lightroom Classic before uninstalling LRCDF.'
}
$prefix = $root.TrimEnd('\') + '\'
if (Get-Process python,pythonw,LRCDF -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}) {
    throw 'Close LRCDF and wait for its photo processing to finish before uninstalling.'
}
$updateLock = Join-Path $root '.update\installing'
if (Test-Path -LiteralPath $updateLock) {
    try {
        $handle = [IO.File]::Open($updateLock, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $handle.Dispose()
    } catch [IO.IOException] {
        throw 'Wait for the LRCDF update to finish before uninstalling.'
    }
}

# Remove only application-owned paths. Leave plugin_work and APPDATA\LRCDF intact.
$ownedNames = @('models', 'legacy', 'python', '.update', '.previous', 'project',
    '.components.json', '.update_build.json', '.update_seen', '.update_result.json')
$targets = @($ownedNames | ForEach-Object { Join-Path $root $_ })
$targets += @(Get-ChildItem -LiteralPath $root -Directory -Filter 'python.previous-*' | ForEach-Object FullName)
foreach ($target in $targets) {
    $absolute = [IO.Path]::GetFullPath($target)
    if (!$absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Uninstall target is outside LRCDF: $absolute"
    }
}
$modules = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'Adobe\Lightroom\Modules'))
$plugin = [IO.Path]::GetFullPath((Join-Path $modules 'LRCDFAuto.lrplugin'))
if ((Split-Path -Parent $plugin) -ne $modules) { throw 'Invalid Lightroom plug-in path.' }
if (Test-Path -LiteralPath $plugin) { Remove-Item -LiteralPath $plugin -Recurse -Force }
foreach ($target in $targets) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

$desktopDirectory = [Environment]::GetFolderPath('DesktopDirectory')
$programsDirectory = [Environment]::GetFolderPath('Programs')
foreach ($shortcutDirectory in @($desktopDirectory, $programsDirectory)) {
    $shortcut = Join-Path $shortcutDirectory 'LRCDF.lnk'
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
}
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LRCDF'
if (Test-Path -LiteralPath $uninstallKey) { Remove-Item -LiteralPath $uninstallKey -Force }
if (!(Get-ChildItem -LiteralPath $root -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $root
}
Write-Output 'LRCDF was uninstalled. Your Lightroom work files and LRCDF user data were kept.'
