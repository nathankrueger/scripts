#Requires -Version 5
<#
.SYNOPSIS
    Strip embedded credentials from github.com remote URLs in every git repo
    under your Windows user profile.

.DESCRIPTION
    Walks $env:USERPROFILE for .git directories, finds remotes whose URLs
    embed credentials (https://user:token@github.com/...), and rewrites them
    to clean URLs. Run once per machine after 'gh auth setup-git'.
    Idempotent — safe to re-run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scrub-git-tokens.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$fixed   = 0
$checked = 0

Write-Host "Scanning $env:USERPROFILE for git repos..."

$gitDirs = Get-ChildItem -Path $env:USERPROFILE -Recurse -Force -Directory `
    -Filter '.git' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }

foreach ($gitDir in $gitDirs) {
    $repo = $gitDir.Parent.FullName
    $checked++

    $remotes = & git -C $repo remote 2>$null
    if (-not $remotes) { continue }

    foreach ($remote in $remotes) {
        if (-not $remote) { continue }
        $url = & git -C $repo remote get-url $remote 2>$null
        if (-not $url) { continue }

        if ($url -match '^https://[^@/]+@github\.com/') {
            $clean = $url -replace '^https://[^@/]+@github\.com/', 'https://github.com/'
            Write-Host "fix: $repo  [$remote]"
            & git -C $repo remote set-url $remote $clean | Out-Null
            $fixed++
        }
    }
}

Write-Host ""
Write-Host "checked $checked repo(s); fixed $fixed remote URL(s)."
