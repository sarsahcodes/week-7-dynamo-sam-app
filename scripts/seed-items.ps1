<#
.SYNOPSIS
    Load the sample orders from seed/sample-orders.json into a deployed table.

.EXAMPLE
    .\scripts\seed-items.ps1 -Environment dev
    .\scripts\seed-items.ps1 -Environment prod -Region eu-central-1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment,

    [string]$Region  = 'eu-central-1',
    [string]$AppName = 'week7-orders'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

# Windows PowerShell 5.1's `Set-Content -Encoding utf8` writes a BOM, and the
# AWS CLI rejects a JSON file that starts with one:
#   Error parsing parameter '--item': Expected: '=', received: 'i'
# Write UTF-8 without a BOM explicitly instead.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    $table = "$AppName-$Environment"
    $items = Get-Content 'seed/sample-orders.json' -Raw | ConvertFrom-Json

    Write-Host "==> writing $($items.Count) items to $table" -ForegroundColor Cyan

    foreach ($item in $items) {
        # aws-cli on Windows mangles inline JSON with nested quotes, so each
        # item goes through a temp file passed as file://
        $tmp = New-TemporaryFile
        try {
            Write-Utf8NoBom -Path $tmp.FullName -Content ($item | ConvertTo-Json -Depth 10 -Compress)

            aws dynamodb put-item `
                --table-name $table `
                --region $Region `
                --item "file://$($tmp.FullName)"

            if ($LASTEXITCODE -ne 0) { throw "put-item failed for $($item.orderId.S)" }
            Write-Host "    put $($item.orderId.S)  $($item.orderStatus.S)"
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "==> done. Item count:" -ForegroundColor Green
    aws dynamodb scan --table-name $table --region $Region --select COUNT --output table
}
finally {
    Pop-Location
}
