#Requires -Version 5.1
<#
.SYNOPSIS
  Build libvips binaries for Windows from a terminal, picking the codecs.

.DESCRIPTION
  PowerShell front end for build-selectable.sh - the terminal equivalent of the
  "Build (selectable OS + codecs)" GitHub Action.

  It asks for the libvips version and the optional codecs, then starts MSYS2
  (UCRT64) and lets build-selectable.sh / build-scripts/win.sh do the actual
  build, so the codec catalogue and the build logic exist in exactly one place.

.PARAMETER Version
  libvips version to build. Omit it to be asked (default: VERSION_VIPS from
  versions.properties).

.PARAMETER Codecs
  Comma separated codec list, or 'all' / 'default' / 'none'. Omit it to be asked.

.PARAMETER Platform
  win-x64 (default) or win-arm64 (requires the CLANGARM64 MSYS2 environment).

.PARAMETER Msys2Root
  MSYS2 installation directory. Auto-detected from $env:MSYS2_INSTALL,
  C:\msys64, C:\msys32 or a bash.exe already on PATH.

.PARAMETER Clean
  Delete deps/ and target/ before building.

.PARAMETER DryRun
  Show what would be built without building anything.

.PARAMETER Yes
  Unattended: ask nothing, use defaults for anything not specified.

.PARAMETER ListCodecs
  Print the codec catalogue and exit.

.EXAMPLE
  .\build-selectable.ps1

.EXAMPLE
  .\build-selectable.ps1 -Codecs jpeg-xl,openjpeg,ppm -Yes

.EXAMPLE
  .\build-selectable.ps1 -DryRun -Codecs all
#>
[CmdletBinding()]
param(
  [string]$Version,
  [string]$Codecs,
  [string]$Platform,
  [string]$Msys2Root,
  [switch]$Clean,
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$ListCodecs
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }

# --- catalogue -------------------------------------------------------------
function Get-ShellVar([string]$Name, [string]$Path) {
  $hit = Select-String -LiteralPath $Path -Pattern ('^{0}="(.*)"$' -f $Name) |
  Select-Object -First 1
  if ($hit) { return $hit.Matches[0].Groups[1].Value }
  return ''
}

$codecsSh = Join-Path $Root 'build-scripts\codecs.sh'
if (-not (Test-Path -LiteralPath $codecsSh)) {
  Write-Error "Could not find $codecsSh - run this script from the repository root."
  exit 1
}

$extraCodecs = @(Get-ShellVar 'CODEC_EXTRA' $codecsSh) -split '\s+' | Where-Object { $_ }
$builtinCodecs = @(Get-ShellVar 'CODEC_BUILTINS_ALL' $codecsSh) -split '\s+' | Where-Object { $_ }
if (-not $extraCodecs -or -not $builtinCodecs) {
  Write-Error 'Could not read CODEC_EXTRA / CODEC_BUILTINS_ALL from build-scripts/codecs.sh.'
  exit 1
}
$allCodecs = @($extraCodecs) + @($builtinCodecs)
$defaultCodecs = @('nsgif', 'qoi')

$CodecNotes = [ordered]@{
  spng      = 'PNG via libspng'
  openjpeg  = 'JPEG 2000 (jp2)'
  openexr   = 'OpenEXR (exr), also builds Imath - NOT available on Windows'
  'jpeg-xl' = 'JPEG XL (jxl), also builds brotli + highway'
  fftw      = 'FFTW, used by FFT-based operations'
  cfitsio   = 'FITS astronomical images'
  matio     = 'MATLAB .mat files'
  raw       = 'Camera RAW via libraw'
  ppm       = 'PPM/PNM (built in, no dependency)'
  analyze   = 'Analyze/.img (built in, no dependency)'
  radiance  = 'Radiance .hdr (built in, no dependency)'
  qoi       = 'QOI (built in, needs libvips >= 8.19)'
  nsgif     = 'GIF loading (built in, no dependency)'
}

$CodecAliases = @{
  'jxl' = 'jpeg-xl'; 'jpegxl' = 'jpeg-xl'; 'libjxl' = 'jpeg-xl'
  'exr' = 'openexr'; 'open-exr' = 'openexr'
  'jp2' = 'openjpeg'; 'jpeg2000' = 'openjpeg'; 'openjpeg2' = 'openjpeg'; 'open-jpeg' = 'openjpeg'
  'libspng' = 'spng'; 'png-spng' = 'spng'
  'libraw' = 'raw'
  'fits' = 'cfitsio'; 'libcfitsio' = 'cfitsio'
  'mat' = 'matio'; 'matlab' = 'matio'
  'fft' = 'fftw'; 'libfftw' = 'fftw'
}

# --- selection helpers ----------------------------------------------------
function Resolve-Choice {
  param([string[]]$Items, [string[]]$Default, [string]$Answer, [hashtable]$Aliases)

  if ([string]::IsNullOrWhiteSpace($Answer)) { return , @($Default) }

  $tokens = ($Answer.ToLower() -replace '[,;]+', ' ').Trim() -split '\s+' |
  Where-Object { $_ }
  $chosen = New-Object System.Collections.Generic.List[string]

  foreach ($token in $tokens) {
    if ($token -eq 'all') { return , @($Items) }
    if ($token -in @('none', 'off', 'no')) { $chosen.Clear(); continue }
    if ($token -eq 'default') {
      $chosen.Clear()
      foreach ($d in $Default) { [void]$chosen.Add($d) }
      continue
    }

    $mapped = $null
    if ($token -match '^(\d+)-(\d+)$') {
      $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
      for ($i = 0; $i -lt $Items.Count; $i++) {
        if (($i + 1) -ge $lo -and ($i + 1) -le $hi) { [void]$chosen.Add($Items[$i]) }
      }
      continue
    }
    if ($token -match '^\d+$') {
      $n = [int]$token
      if ($n -ge 1 -and $n -le $Items.Count) { $mapped = $Items[$n - 1] }
    }
    elseif ($Items -contains $token) { $mapped = $token }
    elseif ($Aliases.ContainsKey($token) -and $Items -contains $Aliases[$token]) { $mapped = $Aliases[$token] }

    if ($mapped) { [void]$chosen.Add($mapped) }
    else { Write-Host "  unknown choice: $token" -ForegroundColor Red; return $null }
  }

  return , @($chosen | Select-Object -Unique)
}

function Show-Menu {
  param([string]$Title, [string[]]$Items, $Notes, [string]$Extra)

  Write-Host ''
  Write-Host $Title -ForegroundColor Cyan
  for ($i = 0; $i -lt $Items.Count; $i++) {
    $note = ''
    if ($Notes.Contains($Items[$i])) { $note = $Notes[$Items[$i]] }
    Write-Host ('   {0,2}) {1,-11} {2}' -f ($i + 1), $Items[$i], $note) -ForegroundColor Gray
  }
  if ($Extra) { Write-Host "        $Extra" -ForegroundColor DarkGray }
}

function Ask-Choice {
  param([string]$Title, [string[]]$Items, [string[]]$Default, $Notes,
    [hashtable]$Aliases, [string]$Extra)

  while ($true) {
    Show-Menu -Title $Title -Items $Items -Notes $Notes -Extra $Extra
    $answer = Read-Host ('Choose [{0}] (numbers, ranges like 1-4, names, all, none, default)' -f ($Default -join ' '))
    $result = Resolve-Choice -Items $Items -Default $Default -Answer $answer -Aliases $Aliases
    if ($null -ne $result) { return $result }
    Write-Host '  nothing selected yet - try again.' -ForegroundColor Yellow
  }
}

# --- MSYS2 discovery ------------------------------------------------------
function Find-Msys2Root([string]$Hint) {
  $candidates = @()
  if ($Hint) { $candidates += $Hint }
  if ($env:MSYS2_INSTALL) { $candidates += $env:MSYS2_INSTALL }
  $candidates += 'C:\msys64'
  $candidates += 'C:\msys32'

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath (Join-Path $candidate 'usr\bin\bash.exe')) { return $candidate }
  }

  $bash = Get-Command bash.exe -ErrorAction SilentlyContinue
  if ($bash -and $bash.Source -match '^(.*?)\\usr\\bin\\bash\.exe$') { return $Matches[1] }
  return $null
}

function ConvertTo-MsysPath([string]$Path) {
  $p = $Path -replace '\\', '/'
  if ($p -match '^([A-Za-z]):/(.*)$') { return '/{0}/{1}' -f $Matches[1].ToLower(), $Matches[2] }
  return $p
}


# --- main -----------------------------------------------------------------
$versionsFile = Join-Path $Root 'versions.properties'
$currentVersion = Get-ShellVar 'VERSION_VIPS' $versionsFile
if (-not $currentVersion) { $currentVersion = '8.18.7' }

if (-not $Platform) { $Platform = 'win-x64' }
if ($Platform -notin @('win-x64', 'win-arm64')) {
  Write-Error "Unknown platform '$Platform' (win-x64 or win-arm64)."
  exit 1
}

$interactive = (-not $Yes) -and (-not [Console]::IsInputRedirected)

Write-Host ''
Write-Host 'libvips-binaries - selectable build (Windows / PowerShell front end)' -ForegroundColor Cyan
Write-Host '  core codecs (always built):' -ForegroundColor DarkGray
Write-Host ("    {0}" -f ($builtinCodecs -join ', ')) -ForegroundColor DarkGray

if ($ListCodecs) {
  Show-Menu -Title 'Optional codecs:' -Items $allCodecs -Notes $CodecNotes
  Write-Host ''
  Write-Host "default selection: $($defaultCodecs -join ', ')"
  exit 0
}

# Version.
if ($Version) {
  if ($Version -notmatch '^[0-9]+(\.[0-9]+){1,3}$') {
    Write-Error "Version '$Version' does not look like a libvips version."
    exit 1
  }
}
elseif ($interactive) {
  $answer = Read-Host "libvips version [$currentVersion]"
  if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $currentVersion }
  if ($answer -notmatch '^[0-9]+(\.[0-9]+){1,3}$') {
    Write-Error "'$answer' does not look like a libvips version."
    exit 1
  }
  $Version = $answer
}
else {
  $Version = $currentVersion
}

# Codecs.
if ($Codecs) {
  $chosenCodecs = Resolve-Choice -Items $allCodecs -Default $defaultCodecs -Answer $Codecs -Aliases $CodecAliases
  if ($null -eq $chosenCodecs) { exit 1 }
}
elseif ($interactive) {
  $chosenCodecs = Ask-Choice -Title 'Optional codecs to build' -Items $allCodecs `
    -Default $defaultCodecs -Notes $CodecNotes -Aliases $CodecAliases `
    -Extra 'extra codecs build an extra dependency, built-in formats cost nothing; openexr is unavailable on Windows'
}
else {
  $chosenCodecs = @($defaultCodecs)
}

if ($Platform -eq 'win-x64' -and $chosenCodecs -contains 'openexr') {
  Write-Host '  openexr is not available on Windows (MSYS2 ships it shared-only): it will be left out.' -ForegroundColor Yellow
  $chosenCodecs = @($chosenCodecs | Where-Object { $_ -ne 'openexr' })
}
$VersionObject = $null
try { $VersionObject = [version]$Version } catch { $VersionObject = $null }
if ($VersionObject -and $VersionObject -lt [version]'8.19.0' -and $chosenCodecs -contains 'qoi') {
  Write-Host "  note: qoi needs libvips >= 8.19; with $Version it will be skipped by the build." -ForegroundColor Yellow
}

# Clean old deps/target?
$cleanFlag = '--no-clean'
if ($Clean) {
  $cleanFlag = '--clean'
}
elseif ($interactive -and ((Test-Path -LiteralPath (Join-Path $Root 'deps')) -or (Test-Path -LiteralPath (Join-Path $Root 'target')))) {
  $answer = Read-Host 'Delete the existing deps/ and target/ directories first? [Y/n]'
  if ($answer -notmatch '^[nN]') { $cleanFlag = '--clean' }
}

Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host 'About to build'
Write-Host "  version   : $Version"
Write-Host "  platform  : $Platform"
if ($chosenCodecs.Count -eq 0) { Write-Host '  codecs    : (none extra)' }
else { Write-Host ('  codecs    : {0}' -f ($chosenCodecs -join ',')) }
Write-Host '------------------------------------------------------------'

if ($interactive -and -not $DryRun) {
  $answer = Read-Host 'Start the build? [y/N]'
  if ($answer -notmatch '^[yY]') { Write-Host 'Aborted.'; exit 0 }
}

$msys2 = Find-Msys2Root $Msys2Root
if (-not $msys2) {
  Write-Error @'
MSYS2 was not found (looked for C:\msys64, C:\msys32 and bash.exe on PATH).

Install MSYS2 from https://www.msys2.org/ and run, in an "MSYS2 UCRT64" shell:
  pacman -S --needed base-devel git mingw-w64-ucrt-x86_64-toolchain
  pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-{meson,ninja,pkg-config,cmake}
'@
  exit 1
}

$bash = Join-Path $msys2 'usr\bin\bash.exe'
$repoUnix = ConvertTo-MsysPath $Root
$codecArg = if ($chosenCodecs.Count -eq 0) { 'none' } else { $chosenCodecs -join ',' }

$shellArgs = @('-p', $Platform, '-c', $codecArg, '-v', $Version, '--yes', $cleanFlag)
if ($DryRun) { $shellArgs += '--dry-run' }
$quoted = ($shellArgs | ForEach-Object { "'{0}'" -f $_ }) -join ' '

$env:MSYSTEM = if ($Platform -eq 'win-arm64') { 'CLANGARM64' } else { 'UCRT64' }

Write-Host ''
Write-Host "  MSYS2  : $msys2 ($env:MSYSTEM)"
Write-Host "  repo   : $repoUnix"
Write-Host ''

& $bash -lc "cd '$repoUnix' && bash build-selectable.sh $quoted"
exit $LASTEXITCODE
