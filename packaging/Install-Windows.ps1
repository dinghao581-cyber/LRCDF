param([switch]$Replace)
$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'LRCDF'
$bundlePython = Join-Path $payload 'python\python.exe'
$bundleApp = Join-Path $payload 'project\app\windows\LRCDF.exe'
$bundleRecord = Join-Path $payload '.update_build.json'
$bundleComponents = Join-Path $payload '.components.json'
$bundleHelper = Join-Path $payload 'project\app\windows\Update-Windows.ps1'
$bundleUninstaller = Join-Path $payload 'project\app\windows\Uninstall-Windows.ps1'
$updatePack = Join-Path $PSScriptRoot 'pack_update_windows.py'
$required = @($bundlePython, $bundleApp, $bundleRecord, $bundleComponents, $bundleHelper, $bundleUninstaller, $updatePack)
if ($required.Where({ !(Test-Path -LiteralPath $_ -PathType Leaf) }).Count -ne 0) {
    throw 'Extract the complete LRCDF bundle before running this script.'
}
$build = Get-Content -Raw -LiteralPath $bundleRecord | ConvertFrom-Json
$variant = switch ($build.platform) {
    'win-x64-cpu' { 'cpu' }
    'win-x64-cu124' { 'cu124' }
    default { throw 'Invalid Windows build in this bundle.' }
}
$destination = Join-Path $env:USERPROFILE 'LRCDF'
$modules = Join-Path $env:APPDATA 'Adobe\Lightroom\Modules'
$plugin = Join-Path $modules 'LRCDFAuto.lrplugin'
if (!$Replace -and ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $plugin))) {
    throw 'An LRCDF installation already exists. Use -Replace only if you want to update these files.'
}
if (Get-Process Lightroom -ErrorAction SilentlyContinue) {
    throw 'Close Lightroom Classic before installing or updating the plug-in.'
}
$pythonw = Join-Path $destination 'python\pythonw.exe'
if (Get-Process pythonw -ErrorAction SilentlyContinue | Where-Object Path -eq $pythonw) {
    throw 'Close the LRCDF desktop application before installing or updating.'
}

function Copy-Tree($Source, $Target, [string[]]$Exclude = @()) {
    $options = if ($Exclude.Count) { @('/XF') + $Exclude } else { @() }
    robocopy $Source $Target /E /R:1 /W:1 /NFL /NDL /NJH /NP @options | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed: $Target (robocopy $LASTEXITCODE)" }
}

$pythonDirectory = Join-Path $destination 'python'
# Two torch builds have different DLLs. Move the previous runtime aside before copying one over the other.
if (Test-Path -LiteralPath $pythonDirectory) {
    $saved = "$pythonDirectory.previous-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Move-Item -LiteralPath $pythonDirectory -Destination $saved
    Write-Output "Previous Python: $saved"
}
Copy-Tree $payload $destination @('.update_build.json', '.components.json')
Copy-Tree "$payload\project\plugin\LRCDFAuto.lrplugin" $plugin
& "$destination\python\python.exe" -s -c "import torch, torchvision, cv2, mediapipe, onnxruntime, imagecodecs; from PySide6.QtWidgets import QApplication; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey; print('Installed PyTorch:', torch.__version__)"
if ($LASTEXITCODE -ne 0) { throw 'Installed Python validation failed.' }
if ($Replace) {
    # A manual upgrade merges files. Record the resulting tree, including any files it retained.
    & "$destination\python\python.exe" -s $updatePack ids $destination --variant $variant --version $build.version
    if ($LASTEXITCODE -ne 0) { throw 'Installed update component identity generation failed.' }
} else {
    Copy-Item -LiteralPath $bundleRecord,$bundleComponents -Destination $destination
}

# A shortcut's AppUserModelID must match the application's taskbar identity.
if (-not ('LRCDFShortcutProperties' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LRCDFShortcutProperties
{
    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid format; public uint id; }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant
    {
        public ushort type, reserved1, reserved2, reserved3;
        public IntPtr text, unused;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHGetPropertyStoreFromParsingName(
        string path, IntPtr bindContext, uint flags, ref Guid iid, out IPropertyStore store);

    public static void SetAppId(string path)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref iid, out store));
        var key = new PropertyKey { format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), id = 5 };
        var value = new PropVariant { type = 31, text = Marshal.StringToCoTaskMemUni("LRCDF.Desktop") };
        try
        {
            Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
            Marshal.ThrowExceptionForHR(store.Commit());
        }
        finally
        {
            Marshal.FreeCoTaskMem(value.text);
            Marshal.ReleaseComObject(store);
        }
    }
}
'@
}
$installedApp = Join-Path $destination 'project\app\windows\LRCDF.exe'
$desktopDirectory = [Environment]::GetFolderPath('DesktopDirectory')
$programsDirectory = [Environment]::GetFolderPath('Programs')
$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutDirectory in @($desktopDirectory, $programsDirectory)) {
    New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
    $shortcutPath = Join-Path $shortcutDirectory 'LRCDF.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $installedApp
    $shortcut.WorkingDirectory = Split-Path -Parent $installedApp
    $shortcut.IconLocation = "$installedApp,0"
    $shortcut.Description = 'LRCDF'
    $shortcut.Save()
    [LRCDFShortcutProperties]::SetAppId($shortcutPath)
}
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LRCDF'
$uninstaller = Join-Path $destination 'project\app\windows\Uninstall-Windows.ps1'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$uninstallCommand = '"' + $powershell + '" -NoProfile -ExecutionPolicy Bypass -File "' + $uninstaller + '"'
New-Item -Path $uninstallKey -Force | Out-Null
foreach ($item in @{
    DisplayName = 'LRCDF'; DisplayVersion = $build.version; Publisher = 'LRCDF';
    DisplayIcon = ('"' + $installedApp + '",0'); InstallLocation = $destination;
    UninstallString = $uninstallCommand; QuietUninstallString = $uninstallCommand
}.GetEnumerator()) {
    New-ItemProperty -LiteralPath $uninstallKey -Name $item.Key -Value $item.Value -PropertyType String -Force | Out-Null
}
New-ItemProperty -LiteralPath $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -LiteralPath $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
Write-Output "LRCDF: $destination"
Write-Output "Desktop app: $destination\project\app\windows\LRCDF.exe"
Write-Output "Lightroom plug-in: $plugin"
