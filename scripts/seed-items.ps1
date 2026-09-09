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

try {
    $table = "$AppName-$Environment"
    $items = Get-Content 'seed/sample-orders.json' -Raw | ConvertFrom-Json

    Write-Host "==> writing $($items.Count) items to $table" -ForegroundColor Cyan

    foreach ($item in $items) {
        # aws-cli on Windows mangles inline JSON, so write each item to a temp
        # file and pass it with the file:// prefix.
        $tmp = New-TemporaryFile
        $item | ConvertTo-Json -Depth 10 -Compress | Set-Content $tmp -Encoding utf8

        aws dynamodb put-item `
            --table-name $table `
            --region $Region `
            --item "file://$($tmp.FullName)"

        if ($LASTEXITCODE -ne 0) { Remove-Item $tmp -Force; throw "put-item failed for $($item.orderId.S)" }
        Remove-Item $tmp -Force
        Write-Host "    put $($item.orderId.S)  $($item.orderStatus.S)"
    }

    Write-Host "==> done. Item count:" -ForegroundColor Green
    aws dynamodb scan --table-name $table --region $Region --select COUNT --output table
}
finally {
    Pop-Location
}
