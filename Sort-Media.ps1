[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot "config.json"),
    [string[]]$Sources,
    [string]$DestinationRoot,
    [string]$ExifTool,
    [string]$LogDir,
    [switch]$VerifyHashAfterCopy
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG
# ============================================================

$configData = $null

if (Test-Path -LiteralPath $Config -PathType Leaf) {
    $configText = [System.IO.File]::ReadAllText(
        (Resolve-Path -LiteralPath $Config),
        [System.Text.Encoding]::UTF8
    )
    $configData = $configText | ConvertFrom-Json
}

function Get-ConfigValue {
    param(
        [string]$Name,
        $Fallback = $null
    )

    if ($null -ne $configData -and $configData.PSObject.Properties.Name -contains $Name) {
        return $configData.$Name
    }

    return $Fallback
}

if (-not $PSBoundParameters.ContainsKey("Sources")) {
    $Sources = @(Get-ConfigValue "sources")
}

if (-not $PSBoundParameters.ContainsKey("DestinationRoot")) {
    $DestinationRoot = [string](Get-ConfigValue "destinationRoot")
}

if (-not $PSBoundParameters.ContainsKey("ExifTool")) {
    $ExifTool = [string](Get-ConfigValue "exifTool")
}

if (-not $PSBoundParameters.ContainsKey("LogDir")) {
    $LogDir = [string](Get-ConfigValue "logDir")

    if ([string]::IsNullOrWhiteSpace($LogDir) -and -not [string]::IsNullOrWhiteSpace($DestinationRoot)) {
        $LogDir = Join-Path (Split-Path -Parent $DestinationRoot) "logs"
    }
}

if ($PSBoundParameters.ContainsKey("VerifyHashAfterCopy")) {
    $verifyHash = [bool]$VerifyHashAfterCopy
}
else {
    $verifyHash = [bool](Get-ConfigValue "verifyHashAfterCopy" $false)
}

$defaultIgnoredDirectories = @(
    '$RECYCLE.BIN'
    'RECYCLER'
    'System Volume Information'
)

$ignoredDirectories = @(Get-ConfigValue "ignoredDirectories" $defaultIgnoredDirectories)
if ($ignoredDirectories.Count -eq 0) {
    $ignoredDirectories = $defaultIgnoredDirectories
}

$defaultPhotos = @(
    "jpg", "jpeg", "png", "heic", "webp", "bmp", "gif", "tif", "tiff",
    "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf"
)

$defaultVideos = @(
    "mp4", "mov", "3gp", "avi", "mts", "m2ts", "mpg", "mpeg",
    "wmv", "mkv", "m4v", "webm", "flv", "asf", "ts"
)

$defaultDvd = @("vob")
$defaultAudio = @("m4a")

$photoExtensions = $defaultPhotos
$videoExtensions = $defaultVideos
$dvdExtensions = $defaultDvd
$audioExtensions = $defaultAudio

if ($null -ne $configData -and $null -ne $configData.extensions) {
    if ($null -ne $configData.extensions.photos) { $photoExtensions = @($configData.extensions.photos) }
    if ($null -ne $configData.extensions.videos) { $videoExtensions = @($configData.extensions.videos) }
    if ($null -ne $configData.extensions.dvd)    { $dvdExtensions = @($configData.extensions.dvd) }
    if ($null -ne $configData.extensions.audio)  { $audioExtensions = @($configData.extensions.audio) }
}

function Normalize-ExtensionList {
    param([object[]]$Items)

    return @(
        $Items |
        ForEach-Object {
            ([string]$_).Trim().TrimStart(".").ToLowerInvariant()
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
}

$photoExtensions = Normalize-ExtensionList $photoExtensions
$videoExtensions = Normalize-ExtensionList $videoExtensions
$dvdExtensions = Normalize-ExtensionList $dvdExtensions
$audioExtensions = Normalize-ExtensionList $audioExtensions

$allExtensions = @(
    $photoExtensions
    $videoExtensions
    $dvdExtensions
    $audioExtensions
) | Select-Object -Unique

# ============================================================
# HELPERS
# ============================================================

function Normalize-PathForCompare {
    param([string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)

    if (-not $full.EndsWith("\")) {
        $full += "\"
    }

    return $full
}

function Get-DateInfo {
    param($Row)

    $candidates = @(
        [PSCustomObject]@{ Name = "DateTimeOriginal"; Value = [string]$Row.DateTimeOriginal; Confidence = "HIGH" }
        [PSCustomObject]@{ Name = "CreateDate";       Value = [string]$Row.CreateDate;       Confidence = "MEDIUM" }
        [PSCustomObject]@{ Name = "MediaCreateDate";  Value = [string]$Row.MediaCreateDate;  Confidence = "MEDIUM" }
        [PSCustomObject]@{ Name = "TrackCreateDate";  Value = [string]$Row.TrackCreateDate;  Confidence = "MEDIUM" }
        [PSCustomObject]@{ Name = "FileModifyDate";   Value = [string]$Row.FileModifyDate;   Confidence = "LOW" }
    )

    $maxYear = (Get-Date).Year + 1

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) {
            continue
        }

        if ($candidate.Value -match '^(?<year>\d{4}):(?<month>\d{2}):(?<day>\d{2})') {
            $year = [int]$Matches["year"]
            $month = [int]$Matches["month"]
            $day = [int]$Matches["day"]

            if (
                $year -ge 1900 -and $year -le $maxYear -and
                $month -ge 1 -and $month -le 12 -and
                $day -ge 1 -and $day -le 31
            ) {
                return [PSCustomObject]@{
                    DateSource = $candidate.Name
                    Confidence = $candidate.Confidence
                    Year       = "{0:D4}" -f $year
                    Month      = "{0:D2}" -f $month
                }
            }
        }
    }

    return [PSCustomObject]@{
        DateSource = ""
        Confidence = "NO_DATE"
        Year       = ""
        Month      = ""
    }
}

function Get-MediaKind {
    param([string]$FileName)

    $ext = [System.IO.Path]::GetExtension($FileName).TrimStart(".").ToLowerInvariant()

    if ($photoExtensions -contains $ext) { return "Photos" }
    if ($dvdExtensions -contains $ext)   { return "DVD" }
    if ($videoExtensions -contains $ext) { return "Videos" }
    if ($audioExtensions -contains $ext) { return "Audio" }

    return "Unknown"
}

function Get-StableFileName {
    param(
        [string]$SourcePath,
        [string]$OriginalFileName
    )

    $extension = [System.IO.Path]::GetExtension($OriginalFileName)

    if ([string]::IsNullOrWhiteSpace($extension)) {
        $extension = [System.IO.Path]::GetExtension($SourcePath)
    }

    if ([string]::IsNullOrWhiteSpace($extension)) {
        $extension = ".bin"
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $normalized = $SourcePath.ToLowerInvariant()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash[0..11] | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha.Dispose()
    }

    return $hex + $extension.ToLowerInvariant()
}

function Csv-Escape {
    param($Value)

    $text = [string]$Value
    return '"' + $text.Replace('"', '""') + '"'
}

function Write-CopyLog {
    param(
        [string]$Status,
        [string]$Source,
        [string]$Destination,
        [string]$MediaKind,
        [string]$DateSource,
        [string]$Confidence,
        [string]$Message
    )

    $line = @(
        (Csv-Escape (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        (Csv-Escape $Status)
        (Csv-Escape $Source)
        (Csv-Escape $Destination)
        (Csv-Escape $MediaKind)
        (Csv-Escape $DateSource)
        (Csv-Escape $Confidence)
        (Csv-Escape $Message)
    ) -join ","

    $script:LogWriter.WriteLine($line)
    $script:LogWriter.Flush()
}

# ============================================================
# VALIDATION
# ============================================================

if ([string]::IsNullOrWhiteSpace($ExifTool)) {
    throw "ExifTool path is not configured. Set exifTool in config.json or use -ExifTool."
}

if (-not (Test-Path -LiteralPath $ExifTool -PathType Leaf)) {
    throw "ExifTool not found: $ExifTool"
}

if ($Sources.Count -eq 0) {
    throw "No source directories configured. Set sources in config.json or use -Sources."
}

if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    throw "Destination is not configured. Set destinationRoot in config.json or use -DestinationRoot."
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    throw "Log directory is not configured."
}

foreach ($source in $Sources) {
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source is not available: $source"
    }
}

$destCompare = Normalize-PathForCompare $DestinationRoot

foreach ($source in $Sources) {
    $sourceCompare = Normalize-PathForCompare $source

    if ($destCompare.StartsWith($sourceCompare, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe destination: '$DestinationRoot' is inside source '$source'."
    }
}

# ============================================================
# DIRECTORIES / LOGS
# ============================================================

New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$baseFolders = @(
    "$DestinationRoot\Photos"
    "$DestinationRoot\Videos"
    "$DestinationRoot\Videos\DVD"
    "$DestinationRoot\Audio"
    "$DestinationRoot\Needs_Check\Low_Confidence_Date"
    "$DestinationRoot\Needs_Check\No_Date"
    "$DestinationRoot\Needs_Check\Unknown_Type"
)

foreach ($folder in $baseFolders) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RawCsv   = Join-Path $LogDir "_media_audit_raw_$timestamp.csv"
$AuditCsv = Join-Path $LogDir "media_audit_$timestamp.csv"
$LogPath  = Join-Path $LogDir "media_copy_$timestamp.csv"

# ============================================================
# EXIFTOOL AUDIT
# ============================================================

$exifArgs = @(
    "-charset"
    "filename=utf8"
    "-r"
    "-csv"

    "-FileName"
    "-Directory"
    "-FileType"
    "-FileSize"
    "-ImageWidth"
    "-ImageHeight"

    "-DateTimeOriginal"
    "-CreateDate"
    "-MediaCreateDate"
    "-TrackCreateDate"
    "-FileModifyDate"

    "-Make"
    "-Model"
)

foreach ($ext in $allExtensions) {
    $exifArgs += "-ext"
    $exifArgs += $ext
}

foreach ($ignoredDir in $ignoredDirectories) {
    $exifArgs += "-i"
    $exifArgs += [string]$ignoredDir
}

foreach ($source in $Sources) {
    if ($source.Contains(" ")) {
        $exifArgs += '"' + $source + '"'
    }
    else {
        $exifArgs += $source
    }
}

Write-Host ""
Write-Host "Scanning media with ExifTool..."
foreach ($source in $Sources) {
    Write-Host "  $source"
}
Write-Host ""

$process = Start-Process `
    -FilePath $ExifTool `
    -ArgumentList $exifArgs `
    -RedirectStandardOutput $RawCsv `
    -NoNewWindow `
    -PassThru `
    -Wait

if (-not (Test-Path -LiteralPath $RawCsv -PathType Leaf)) {
    throw "ExifTool did not create an audit CSV."
}

if ($process.ExitCode -ne 0) {
    Write-Warning "ExifTool exited with code $($process.ExitCode). The audit file exists, so processing will continue."
}

# Add UTF-8 BOM for Windows PowerShell / Excel.
$bytes = [System.IO.File]::ReadAllBytes($RawCsv)
$bom = [byte[]](0xEF, 0xBB, 0xBF)

$result = New-Object byte[] ($bom.Length + $bytes.Length)
[System.Array]::Copy($bom, 0, $result, 0, $bom.Length)
[System.Array]::Copy($bytes, 0, $result, $bom.Length, $bytes.Length)

[System.IO.File]::WriteAllBytes($AuditCsv, $result)
Remove-Item -LiteralPath $RawCsv -Force

$rows = @(Import-Csv -LiteralPath $AuditCsv)
$total = $rows.Count

# ============================================================
# COPY LOG
# ============================================================

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, $utf8Bom)

$script:LogWriter.WriteLine(
    '"Timestamp","Status","Source","Destination","MediaKind","DateSource","Confidence","Message"'
)
$script:LogWriter.Flush()

# ============================================================
# COPY
# ============================================================

$seenSources = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

$copied = 0
$alreadyOk = 0
$missing = 0
$errors = 0
$duplicateRows = 0

Write-Host "Media files found: $total"
Write-Host "Destination:       $DestinationRoot"
Write-Host "Audit CSV:         $AuditCsv"
Write-Host "Copy log:          $LogPath"
Write-Host ""
Write-Host "Source files will NOT be moved or deleted."
Write-Host ""

for ($i = 0; $i -lt $total; $i++) {
    $row = $rows[$i]
    $source = ([string]$row.SourceFile).Replace("/", "\")

    $percent = if ($total -gt 0) {
        [math]::Floor((($i + 1) / [double]$total) * 100)
    }
    else {
        100
    }

    Write-Progress `
        -Activity "Sorting and copying media" `
        -Status "$($i + 1) / $total | copied: $copied | already OK: $alreadyOk | errors: $errors" `
        -PercentComplete $percent

    if (-not $seenSources.Add($source)) {
        $duplicateRows++

        Write-CopyLog `
            -Status "SKIP_DUPLICATE_ROW" `
            -Source $source `
            -Destination "" `
            -MediaKind "" `
            -DateSource "" `
            -Confidence "" `
            -Message "Duplicate SourceFile row in audit CSV"

        continue
    }

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $missing++

        Write-CopyLog `
            -Status "MISSING" `
            -Source $source `
            -Destination "" `
            -MediaKind "" `
            -DateSource "" `
            -Confidence "" `
            -Message "Source file does not exist"

        continue
    }

    $destination = ""
    $kind = ""
    $dateInfo = $null

    try {
        $dateInfo = Get-DateInfo -Row $row
        $kind = Get-MediaKind -FileName ([string]$row.FileName)

        if ($kind -eq "DVD") {
            if ($dateInfo.Confidence -eq "NO_DATE") {
                $destinationDir = Join-Path $DestinationRoot "Videos\DVD\Unknown_Date"
            }
            else {
                $destinationDir = Join-Path `
                    $DestinationRoot `
                    ("Videos\DVD\{0}\{1}" -f $dateInfo.Year, $dateInfo.Month)
            }
        }
        elseif ($kind -eq "Unknown") {
            $destinationDir = Join-Path $DestinationRoot "Needs_Check\Unknown_Type"
        }
        elseif ($dateInfo.Confidence -eq "NO_DATE") {
            $destinationDir = Join-Path `
                $DestinationRoot `
                ("Needs_Check\No_Date\{0}" -f $kind)
        }
        elseif ($dateInfo.Confidence -eq "LOW") {
            $destinationDir = Join-Path `
                $DestinationRoot `
                ("Needs_Check\Low_Confidence_Date\{0}\{1}\{2}" -f $kind, $dateInfo.Year, $dateInfo.Month)
        }
        else {
            $destinationDir = Join-Path `
                $DestinationRoot `
                ("{0}\{1}\{2}" -f $kind, $dateInfo.Year, $dateInfo.Month)
        }

        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

        $stableName = Get-StableFileName `
            -SourcePath $source `
            -OriginalFileName ([string]$row.FileName)

        $destination = Join-Path $destinationDir $stableName
        $sourceInfo = Get-Item -LiteralPath $source -ErrorAction Stop

        # Idempotent re-run: same source path -> same destination name.
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationInfo = Get-Item -LiteralPath $destination -ErrorAction Stop

            if ($sourceInfo.Length -eq $destinationInfo.Length) {
                $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash
                $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash

                if ($sourceHash -eq $destinationHash) {
                    $alreadyOk++

                    Write-CopyLog `
                        -Status "ALREADY_OK" `
                        -Source $source `
                        -Destination $destination `
                        -MediaKind $kind `
                        -DateSource $dateInfo.DateSource `
                        -Confidence $dateInfo.Confidence `
                        -Message "Destination already contains identical file"

                    continue
                }
            }

            # Never overwrite a different file.
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($stableName)
            $fileExt = [System.IO.Path]::GetExtension($stableName)
            $suffix = 2

            do {
                $destination = Join-Path $destinationDir ("{0}_{1}{2}" -f $baseName, $suffix, $fileExt)
                $suffix++
            }
            while (Test-Path -LiteralPath $destination)
        }

        Copy-Item `
            -LiteralPath $source `
            -Destination $destination `
            -ErrorAction Stop

        $destinationInfo = Get-Item -LiteralPath $destination -ErrorAction Stop

        if ($sourceInfo.Length -ne $destinationInfo.Length) {
            throw "Size mismatch after copy: source=$($sourceInfo.Length), destination=$($destinationInfo.Length)"
        }

        if ($verifyHash) {
            $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash

            if ($sourceHash -ne $destinationHash) {
                throw "SHA256 mismatch after copy"
            }
        }

        $copied++

        Write-CopyLog `
            -Status "COPIED" `
            -Source $source `
            -Destination $destination `
            -MediaKind $kind `
            -DateSource $dateInfo.DateSource `
            -Confidence $dateInfo.Confidence `
            -Message "OK"
    }
    catch {
        $errors++

        $dateSource = ""
        $confidence = ""

        if ($null -ne $dateInfo) {
            $dateSource = $dateInfo.DateSource
            $confidence = $dateInfo.Confidence
        }

        Write-CopyLog `
            -Status "ERROR" `
            -Source $source `
            -Destination $destination `
            -MediaKind $kind `
            -DateSource $dateSource `
            -Confidence $confidence `
            -Message $_.Exception.Message
    }
}

Write-Progress -Activity "Sorting and copying media" -Completed

$script:LogWriter.Flush()
$script:LogWriter.Close()

Write-Host ""
Write-Host "========================================"
Write-Host "DONE"
Write-Host "========================================"
Write-Host "Media files found:    $total"
Write-Host "Copied:               $copied"
Write-Host "Already OK:            $alreadyOk"
Write-Host "Missing sources:       $missing"
Write-Host "Errors:                $errors"
Write-Host "Duplicate audit rows:  $duplicateRows"
Write-Host ""
Write-Host "Destination: $DestinationRoot"
Write-Host "Audit CSV:   $AuditCsv"
Write-Host "Copy log:    $LogPath"
Write-Host ""
Write-Host "No source files were moved or deleted."
