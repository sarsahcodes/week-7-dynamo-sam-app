<#
.SYNOPSIS
    Validate, build and deploy the DynamoDB stack for one environment.

.DESCRIPTION
    PowerShell equivalent of the manual deploy documented in the README.
    Resolves the environment's artifact bucket from the bootstrap stack, so
    the account id and region never have to be typed by hand.

.EXAMPLE
    .\scripts\deploy.ps1 -Environment dev
    .\scripts\deploy.ps1 -Environment prod
    .\scripts\deploy.ps1 -Environment dev -SkipValidate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment,

    [string]$Region = 'eu-central-1',

    [string]$AppName = 'week7-orders',

    [switch]$SkipValidate
)

$ErrorActionPreference = 'Stop'

# Run from the repo root regardless of where the script was invoked from.
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

try {
    $env:AWS_REGION = $Region

    foreach ($tool in 'aws', 'sam') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool is not on PATH. Install it and reopen the terminal."
        }
    }

    Write-Host "==> resolving the $Environment artifact bucket" -ForegroundColor Cyan
    $bucket = aws cloudformation describe-stacks `
        --stack-name "$AppName-artifacts-$Environment" `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" `
        --output text

    if ([string]::IsNullOrWhiteSpace($bucket) -or $bucket -eq 'None') {
        throw "No artifact bucket found. Deploy bootstrap/artifact-bucket.yaml for '$Environment' first."
    }
    Write-Host "    $bucket"

    if (-not $SkipValidate) {
        Write-Host "==> sam validate --lint" -ForegroundColor Cyan
        sam validate --lint --region $Region
        if ($LASTEXITCODE -ne 0) { throw "sam validate failed" }
    }

    Write-Host "==> sam build" -ForegroundColor Cyan
    sam build
    if ($LASTEXITCODE -ne 0) { throw "sam build failed" }

    Write-Host "==> sam deploy ($Environment)" -ForegroundColor Cyan
    sam deploy --config-env $Environment --s3-bucket $bucket
    if ($LASTEXITCODE -ne 0) { throw "sam deploy failed" }

    Write-Host "==> deployed table" -ForegroundColor Green
    aws dynamodb describe-table `
        --table-name "$AppName-$Environment" `
        --region $Region `
        --query 'Table.{Name:TableName,Status:TableStatus,Billing:BillingModeSummary.BillingMode,Class:TableClassSummary.TableClass,GSIs:GlobalSecondaryIndexes[].IndexName}' `
        --output table
}
finally {
    Pop-Location
}
