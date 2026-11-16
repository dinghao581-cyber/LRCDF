param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidateRange(1, 1999999999)][long]$PartSizeBytes = 1900000000
)
$ErrorActionPreference = 'Stop'
$archive = Get-Item -LiteralPath $ArchivePath
if ($archive.PSIsContainer -or $archive.Extension -ne '.zip' -or $archive.Length -eq 0) {
    throw 'ArchivePath must be a nonempty ZIP file.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$joinScript = Join-Path $OutputDirectory 'Join-Bundle.ps1'
if (Test-Path -LiteralPath $joinScript) { throw "File already exists: $joinScript" }

$parts = @()
[long]$remaining = $archive.Length
$index = 1
while ($remaining -gt 0) {
    $name = '{0}.{1:D3}' -f $archive.Name, $index
    $path = Join-Path $OutputDirectory $name
    if (Test-Path -LiteralPath $path) { throw "File already exists: $path" }
    [long]$length = [Math]::Min($PartSizeBytes, $remaining)
    $parts += [PSCustomObject]@{ Name = $name; Length = $length }
    $remaining -= $length
    $index++
}

$buffer = New-Object byte[] (4MB)
$source = [IO.File]::OpenRead($archive.FullName)
try {
    foreach ($part in $parts) {
        $target = [IO.File]::Open((Join-Path $OutputDirectory $part.Name), [IO.FileMode]::CreateNew)
        try {
            [long]$left = $part.Length
            while ($left -gt 0) {
                $count = $source.Read($buffer, 0, [int][Math]::Min($buffer.Length, $left))
                if ($count -eq 0) { throw 'The input ZIP ended before the expected size.' }
                $target.Write($buffer, 0, $count)
                $left -= $count
            }
        } finally { $target.Dispose() }
        Write-Output ('Created {0} ({1} bytes)' -f $part.Name, $part.Length)
    }
} finally { $source.Dispose() }

$partRows = ($parts | ForEach-Object {
    "    @{ Name = '$($_.Name.Replace("'", "''"))'; Length = $($_.Length) }"
}) -join ",`r`n"
$script = @'
param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$archiveName = '__ARCHIVE_NAME__'
$parts = @(
__PART_ROWS__
)
foreach ($part in $parts) {
    $path = Join-Path $PSScriptRoot $part.Name
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing part: $($part.Name)" }
    if ((Get-Item -LiteralPath $path).Length -ne $part.Length) { throw "Incomplete part: $($part.Name)" }
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$output = Join-Path $OutputDirectory $archiveName
if (Test-Path -LiteralPath $output) { throw "File already exists: $output" }
$destination = [IO.File]::Open($output, [IO.FileMode]::CreateNew)
try {
    foreach ($part in $parts) {
        $source = [IO.File]::OpenRead((Join-Path $PSScriptRoot $part.Name))
        try { $source.CopyTo($destination, 4MB) } finally { $source.Dispose() }
    }
} finally { $destination.Dispose() }
Write-Output "Joined ZIP: $output"
Write-Output 'Extract this ZIP, then follow Windows-Install.md inside the extracted folder.'
'@
$script = $script.Replace('__ARCHIVE_NAME__', $archive.Name.Replace("'", "''")).Replace('__PART_ROWS__', $partRows)
[IO.File]::WriteAllText($joinScript, $script, (New-Object Text.UTF8Encoding($true)))
Write-Output "Join script: $joinScript"
