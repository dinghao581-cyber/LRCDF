param(
    [string]$PythonRuntime,
    [string]$OutputDirectory,
    [ValidateSet('cpu','cu124')][string]$Variant = 'cpu',
    [ValidatePattern('^[0-9]+(?:\.[0-9]+){1,3}$')][string]$ReleaseVersion = '0.1.2',
    [string]$ReuseLauncherFrom,
    [string]$ReusePythonFrom,       # the python folder of the release whose Python component stays published
    [switch]$NewPythonIdentity,     # the dependencies changed, or a private build: no published baseline
    [switch]$SlimTested             # also remove the packages a full test run proved unnecessary
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $project
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$bundleName = "LRCDF-Windows-x64-$Variant"
$bundle = Join-Path $OutputDirectory $bundleName
$archive = Join-Path $OutputDirectory "$bundleName.zip"
if ((Test-Path -LiteralPath $bundle) -or (Test-Path -LiteralPath $archive)) {
    throw "Bundle already exists in $OutputDirectory. Choose a new output directory."
}

function Copy-Tree($Source, $Destination, [string[]]$Exclude = @()) {
    if (!(Test-Path -LiteralPath $Source -PathType Container)) { throw "Missing payload: $Source" }
    robocopy $Source $Destination /E /R:1 /W:1 /NFL /NDL /NJH /NP /XD __pycache__ @Exclude | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed: $Source (robocopy $LASTEXITCODE)" }
}

if (!$ReusePythonFrom) {
    if (!$PythonRuntime) {
        uv python install 3.12.13 --no-bin
        if ($LASTEXITCODE -ne 0) { throw 'uv python install failed.' }
        $PythonRuntime = Split-Path -Parent (uv python find --managed-python 3.12.13)
        if ($LASTEXITCODE -ne 0) { throw 'uv could not locate portable Python.' }
    }
    $sourcePython = Join-Path $PythonRuntime 'python.exe'
    if (!(Test-Path -LiteralPath $sourcePython -PathType Leaf) -or (Test-Path -LiteralPath "$PythonRuntime\pyvenv.cfg")) {
        throw 'PythonRuntime must point to a python-build-standalone install directory.'
    }
}
$payload = Join-Path $bundle 'LRCDF'
$portable = Join-Path $payload 'python'
$python = Join-Path $portable 'python.exe'
if ($ReusePythonFrom) {
    Copy-Tree $ReusePythonFrom $portable
} else {
    Copy-Tree $PythonRuntime $portable
    uv pip install --python $python --break-system-packages --torch-backend $Variant -r "$PSScriptRoot\requirements-windows.txt" "torch==2.6.0+$Variant" "torchvision==0.21.0+$Variant"
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
    uv pip check --python $python
    if ($LASTEXITCODE -ne 0) { throw 'Dependency validation failed.' }
}
function Test-BundledPython {
    & $python -s -c "import sys, struct, torch, torchvision, cv2, mediapipe, onnxruntime, imagecodecs; from PySide6.QtWidgets import QApplication; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey; assert sys.version_info[:2] == (3, 12) and struct.calcsize('P') == 8; assert (torch.version.cuda or 'cpu') == {'cpu':'cpu','cu124':'12.4'}[sys.argv[1]]; assert hasattr(cv2, 'FaceRecognizerSF_create'); print(sys.version.split()[0], torch.__version__, torchvision.__version__)" $Variant
    if ($LASTEXITCODE -ne 0) { throw 'Bundled Python validation failed.' }
}
Test-BundledPython
$slimArguments = @('slim', $payload, '--variant', $Variant)
if ($NewPythonIdentity) { $slimArguments += '--new-identity' }
if ($SlimTested) { $slimArguments += '--tested' }
& $python -s (Join-Path $PSScriptRoot 'pack_update_windows.py') @slimArguments
if ($LASTEXITCODE -ne 0) { throw 'Python slimming failed.' }
Test-BundledPython

$projectPayload = Join-Path $payload 'project'
Copy-Tree "$project\lrcdf" "$projectPayload\lrcdf"
$appPayload = Join-Path $projectPayload 'app\windows'
Copy-Tree "$project\app\windows" $appPayload
$launcher = Join-Path $appPayload 'LRCDF.exe'
if ($ReuseLauncherFrom) {
    # Framework csc embeds build-specific metadata. Both variants use the same app-win executable.
    Copy-Item -LiteralPath $ReuseLauncherFrom -Destination $launcher
} else {
    $launcherSource = Join-Path $PSScriptRoot 'Windows-Launcher.cs'
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /r:System.Windows.Forms.dll "/win32icon:$project\app\windows\LRCDF.ico" "/out:$launcher" $launcherSource
    if ($LASTEXITCODE -ne 0) { throw 'Windows launcher compilation failed.' }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Update-Windows.ps1') -Destination $appPayload
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-Windows.ps1') -Destination $appPayload
Copy-Tree "$project\plugin" "$projectPayload\plugin"
Copy-Tree "$project\scripts" "$projectPayload\scripts" @('win3090')
Copy-Tree "$project\runs" "$projectPayload\runs"
Copy-Tree "$root\models" "$payload\models"
Copy-Tree "$root\legacy\mac_project" "$payload\legacy\mac_project"
Copy-Tree "$project\legal" "$projectPayload\legal"
Copy-Item -LiteralPath "$project\styles.json","$project\LICENSE","$project\NOTICE" -Destination $projectPayload
foreach ($required in @('LICENSE', 'NOTICE', 'legal\THIRD_PARTY_NOTICES.md', 'legal\MODEL_LICENSES.md', 'legal\licenses\APPLE_ML_RESEARCH_MODEL_LICENSE.txt')) {
    $file = Join-Path $projectPayload $required
    if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw "Missing licence file: $required" }
}
Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
& $python -s (Join-Path $PSScriptRoot 'precompile_windows.py') $payload
if ($LASTEXITCODE -ne 0) { throw 'Bytecode precompilation failed.' }
$env:PYTHONDONTWRITEBYTECODE = '1'      # nothing after this point writes bytecode of another kind into the bundle
$updatePack = Join-Path $PSScriptRoot 'pack_update_windows.py'
& $python -s $updatePack ids $payload --variant $Variant --version $ReleaseVersion
if ($LASTEXITCODE -ne 0) { throw 'Update component identity generation failed.' }
Copy-Item -LiteralPath "$PSScriptRoot\Install-Windows.ps1","$PSScriptRoot\Windows-Install.md",$updatePack -Destination $bundle
tar.exe -a -cf $archive -C $OutputDirectory $bundleName
if ($LASTEXITCODE -ne 0) { throw 'Archive creation failed.' }
Get-Item -LiteralPath $archive | Select-Object FullName, Length
