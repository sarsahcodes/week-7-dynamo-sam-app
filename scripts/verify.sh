#!/usr/bin/env bash
# Prove every rubric item against the live table:
#   ./scripts/verify.sh dev
set -euo pipefail
ENVIRONMENT="${1:?usage: verify.sh <dev|prod>}"
TABLE="week7-orders-${ENVIRONMENT}"
REGION="${AWS_REGION:-eu-central-1}"

echo "== Table configuration =="
aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" \
  --query '{
      Table:Table.TableName,
      BillingMode:Table.BillingModeSummary.BillingMode,
      TableClass:Table.TableClassSummary.TableClass,
      KeySchema:Table.KeySchema,
      GSIs:Table.GlobalSecondaryIndexes[].{Name:IndexName,Keys:KeySchema,Projection:Projection.ProjectionType}
  }' --output json

echo
echo "== GSI 1: orders for CUST-001 (CustomerOrdersIndex) =="
aws dynamodb query --table-name "$TABLE" --region "$REGION" \
  --index-name CustomerOrdersIndex \
  --key-condition-expression "customerId = :c" \
  --expression-attribute-values '{":c":{"S":"CUST-001"}}' \
  --output table

echo
echo "== GSI 2: PENDING orders (OrderStatusIndex) =="
aws dynamodb query --table-name "$TABLE" --region "$REGION" \
  --index-name OrderStatusIndex \
  --key-condition-expression "orderStatus = :s" \
  --expression-attribute-values '{":s":{"S":"PENDING"}}' \
  --output table
