#!/usr/bin/env bash
# Load the sample orders into a deployed table:
#   ./scripts/seed-items.sh dev
set -euo pipefail
ENVIRONMENT="${1:?usage: seed-items.sh <dev|prod>}"
TABLE="week7-orders-${ENVIRONMENT}"
REGION="${AWS_REGION:-eu-central-1}"

python3 - "$TABLE" "$REGION" <<'PY'
import json, subprocess, sys
table, region = sys.argv[1], sys.argv[2]
items = json.load(open("seed/sample-orders.json"))
for item in items:
    subprocess.run(
        ["aws", "dynamodb", "put-item",
         "--table-name", table, "--region", region,
         "--item", json.dumps(item)],
        check=True)
    print("put", item["orderId"]["S"])
print(f"{len(items)} items written to {table}")
PY
