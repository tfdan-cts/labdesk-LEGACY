# Sets LabDesk's version in every file that carries it. See docs/VERSIONING.md.
# Usage: pwsh scripts/set-version.ps1 1.2.0
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') {
  throw "Not a version: '$Version'. Expected MAJOR.MINOR.PATCH with an optional -suffix."
}
$root = Split-Path $PSScriptRoot -Parent
$pending = [ordered]@{}
function Rewrite($rel, $pattern, $replacement) {
  $path = Join-Path $root $rel
  $text = if ($pending.Contains($rel)) { $pending[$rel] } else { [IO.File]::ReadAllText($path) }
  $next = [regex]::Replace($text, $pattern, $replacement, [Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not [regex]::IsMatch($text, $pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) { throw "${rel}: nothing matched $pattern" }
  $pending[$rel] = $next
}
# Build number: the current one plus one, never reused.
$pubspec = [IO.File]::ReadAllText((Join-Path $root 'flutter/pubspec.yaml'))
# Files may carry CRLF endings, so a value runs to the end of the line, not to $.
$m = [regex]::Match($pubspec, '(?m)^version:\s*[^\r\n]*\+(\d+)')
if (-not $m.Success) { throw 'flutter/pubspec.yaml: no version: X.Y.Z+N line' }
$build = [int]$m.Groups[1].Value + 1
$bare = $Version -replace '-.*$', ''   # RPM Version uses numeric fields.
Rewrite 'flutter/pubspec.yaml' '(?m)^version:[^\r\n]*' "version: $Version+$build"
Rewrite 'Cargo.toml' '(?m)^version = "[^"]+"' "version = `"$Version`""
Rewrite 'libs/portable/Cargo.toml' '(?m)^version = "[^"]+"' "version = `"$Version`""
Rewrite '.github/workflows/flutter-build.yml' '(?m)^  VERSION: "[^"]+"' "  VERSION: `"$Version`""
Rewrite 'appimage/AppImageBuilder-x86_64.yml' '(?m)^(\s+version:)[^\r\n]*' "`$1 $bare"
Rewrite 'appimage/AppImageBuilder-aarch64.yml' '(?m)^(\s+version:)[^\r\n]*' "`$1 $bare"
foreach ($spec in 'res/rpm.spec', 'res/rpm-flutter.spec', 'res/rpm-suse.spec', 'res/rpm-flutter-suse.spec') {
  Rewrite $spec '(?m)^Version:\s+[^\r\n]*' "Version:    $bare"
}
# The lockfiles record our own crates' versions too; cargo would rewrite them on the next build,
# but a --locked build must not be the thing that discovers the mismatch.
Rewrite 'Cargo.lock' '(?m)^(name = "labdesk"\r?\nversion = )"[^"]+"' "`$1`"$Version`""
Rewrite 'Cargo.lock' '(?m)^(name = "labdesk-portable-packer"\r?\nversion = )"[^"]+"' "`$1`"$Version`""
Rewrite 'libs/portable/Cargo.lock' '(?m)^(name = "labdesk-portable-packer"\r?\nversion = )"[^"]+"' "`$1`"$Version`""
# Validate every input before changing any file; both Cargo.lock rewrites compose in memory.
foreach ($rel in $pending.Keys) {
  [IO.File]::WriteAllText((Join-Path $root $rel), $pending[$rel], (New-Object Text.UTF8Encoding($false)))
  "$rel"
}
"version $Version, build $build"
