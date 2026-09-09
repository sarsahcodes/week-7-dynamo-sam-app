<#
.SYNOPSIS
    Prove every rubric item against the live table: configuration, then one
    query against each Global Secondary Index.

.EXAMPLE
    .\scripts\verify.ps1 -Environment dev
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
$table = "$AppName-$Environment"

# aws-cli on Windows mishandles inline JSON with nested quotes, so every
# --expression-attribute-values payload goes through a temp file.
function Invoke-GsiQuery {
    param([string]$Index, [string]$KeyCondition, [string]$Placeholder, [string]$Value)

    $tmp = New-TemporaryFile
    @{ $Placeholder = @{ S = $Value } } | ConvertTo-Json -Depth 5 -Compress |
        Set-Content $tmp -Encoding utf8
    try {
        aws dynamodb query --table-name $table --region $Region `
            --index-name $Index `
            --key-condition-expression $KeyCondition `
            --expression-attribute-values "file://$($tmp.FullName)" `
            --output table
    }
    finally { Remove-Item $tmp -Force }
}

Write-Host "== Table configuration ==" -ForegroundColor Cyan
aws dynamodb describe-table --table-name $table --region $Region `
    --query '{Table:Table.TableName,BillingMode:Table.BillingModeSummary.BillingMode,TableClass:Table.TableClassSummary.TableClass,KeySchema:Table.KeySchema,GSIs:Table.GlobalSecondaryIndexes[].{Name:IndexName,Projection:Projection.ProjectionType}}' `
    --output json

Write-Host "`n== GSI 1: orders for CUST-001 (CustomerOrdersIndex) ==" -ForegroundColor Cyan
Invoke-GsiQuery -Index 'CustomerOrdersIndex' -KeyCondition 'customerId = :c' -Placeholder ':c' -Value 'CUST-001'

Write-Host "`n== GSI 2: PENDING orders (OrderStatusIndex) ==" -ForegroundColor Cyan
Invoke-GsiQuery -Index 'OrderStatusIndex' -KeyCondition 'orderStatus = :s' -Placeholder ':s' -Value 'PENDING'
