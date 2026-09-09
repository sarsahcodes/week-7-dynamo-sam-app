# Console verification walkthrough

Everything below is done in the AWS Console against `week7-orders-dev`
(repeat on `week7-orders-prod` if the reviewer asks). Take a screenshot at each
numbered heading — that is the evidence for the *Verification & Usability* rubric item.

---

## 0. Confirm the table configuration

**DynamoDB → Tables → `week7-orders-dev`**, then the **Overview** and **Indexes** tabs.

| Look for | Expected |
| --- | --- |
| Status | `Active` |
| Capacity mode | `On-demand` |
| Table class | `DynamoDB Standard-IA` |
| Partition key | `orderId (String)` |
| Sort key | `createdAt (String)` |
| Indexes tab | `CustomerOrdersIndex` and `OrderStatusIndex`, both `Active` |

If *Table class* reads `DynamoDB Standard` the wrong template was deployed — the
pipeline's verification step would have failed too.

---

## 1. CREATE — insert an item by hand

**Explore table items → Create item → JSON view** (toggle *View DynamoDB JSON* **off**),
paste:

```json
{
  "orderId": "ORD-2001",
  "createdAt": "2026-09-09T10:00:00Z",
  "customerId": "CUST-004",
  "orderStatus": "PENDING",
  "totalAmount": 599.99,
  "currency": "GHS",
  "itemCount": 5
}
```

**Create item.** Repeat with a second item so the GSI queries return more than one row —
change `orderId` to `ORD-2002`, `createdAt` to `2026-09-09T11:30:00Z`, and keep
`customerId` as `CUST-004`.

> A faster way to fill the table: `./scripts/seed-items.sh dev` loads five orders across
> three customers and four statuses.

---

## 2. READ — get the item back

On **Explore table items**, choose **Query**, leave the source as the table itself, and set:

* Partition key `orderId` = `ORD-2001`
* Sort key `createdAt` — leave the condition blank, or use *Equal to* `2026-09-09T10:00:00Z`

**Run.** One item comes back. Click `ORD-2001` to open the full item view.

---

## 3. QUERY GSI 1 — every order for one customer

Still on **Explore table items → Query**, change the source dropdown from the table to
**`CustomerOrdersIndex`**, then:

* Partition key `customerId` = `CUST-004`
* Sort order: **Descending** (newest order first)

**Run.** Both items appear. Because this index projects `ALL`, every attribute is
returned without a second read against the base table.

---

## 4. QUERY GSI 2 — every order in one status

Change the source to **`OrderStatusIndex`**:

* Partition key `orderStatus` = `PENDING`

**Run.** All pending orders across every customer come back. Note that the returned
items carry only `orderId`, `createdAt`, `orderStatus`, `customerId`, `totalAmount` and
`currency` — that is the `INCLUDE` projection doing its job; `itemCount` is deliberately
not projected.

---

## 5. UPDATE — change an item

Open `ORD-2001` from any of the result lists → **Edit**. Change `orderStatus` from
`PENDING` to `SHIPPED` and **Save changes**.

Re-run the GSI 2 query for `PENDING` — `ORD-2001` is gone. Run it again for `SHIPPED` —
it is there. That single edit moving between indexes is the clearest demonstration that
the GSIs are live and maintained by DynamoDB.

---

## 6. DELETE — remove an item

Select `ORD-2002` in the item list → **Actions → Delete items → Delete**.
Re-run the `CustomerOrdersIndex` query for `CUST-004`: only `ORD-2001` remains.

---

## 7. Show the pipeline evidence

* **GitHub → Actions → Deploy DEV** — open the newest green run. The
  *Verify deployed table against the lab requirements* step prints the billing mode,
  table class and both GSI names, and the job summary shows them in a table.
* **GitHub → Actions → Deploy PROD** — show the approval gate on the `prod` environment
  and the change-set preview in the summary.
* **S3 → Buckets** — show `…-sam-artifacts-dev-…` and `…-sam-artifacts-prod-…` side by
  side, each holding only its own environment's packaged templates.
* **CloudFormation → Stacks** — `week7-orders-dev` and `week7-orders-prod` as two
  independent stacks.
