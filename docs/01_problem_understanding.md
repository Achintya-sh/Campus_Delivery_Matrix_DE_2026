# Phase 1: Problem Understanding & Workload Classification

## 1. Business Context
Zomato operates a three-sided food delivery marketplace across **10 Indian cities** (100 localities), connecting **customers**, **restaurant partners**, and **delivery partners** (riders), alongside internal teams (**Dispatch/Ops, Fleet, Payments/Risk, Gold/Marketing, Customer Support, and Leadership**). Because the legacy database lacks documented constraints and indexing, operational and analytical queries suffer from high latency or incorrect results as volume scales toward 20×.

---

## 2. Analysis of Reported Problems (P1–P10)

| # | Business Need (In Our Own Words) | Affected Stakeholder(s) | Related Queries | Classification | Target SLA (20× Scale) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **P1** | **Fast restaurant discovery & menu browsing:** Customers browsing open restaurants in their locality (`R01`), filtering by cuisine (`R25`), or opening a restaurant's menu (`R03`) during lunch/dinner peaks need sub-second responses to prevent cart abandonment. | Customers, Restaurant Partners | `R01`, `R03`, `R25` | **Customer-facing / Real-time** (`R01`, `R03`) & **Interactive Search** (`R25`) | `< 5 ms` (`R01`, `R03`), `< 250 ms` (`R25`) |
| **P2** | **Low-latency dish type-ahead search:** Customers typing dish keywords like `"paneer"` or `"biryani"` (`R02`) expect instant autocomplete suggestions across available menu items in their city. | Customers, Search Team | `R02` | **Customer-facing / Interactive Search** | `< 250 ms` |
| **P3** | **Instant order history & itemised receipts:** Customers checking their 10 most recent orders (`R04`) or opening an itemised bill with payment status (`R24`) need immediate page loads. | Customers, Customer Support | `R04`, `R24` | **Customer-facing / Real-time** | `< 5 ms` |
| **P4** | **Live restaurant partner operations & menu control:** Restaurant managers need instant access to today's incoming orders (`R06`), rapid toggling of sold-out menu categories (`W03`), and timely monthly/30-day dish sales & bestseller rankings (`R07`, `R08`). | Restaurant Partners | `R06`, `R07`, `R08`, `W03` | **Real-time Partner Ops** (`R06`, `W03`) & **Reporting / Analytics** (`R07`, `R08`) | `< 5 ms` (`R06`, `W03`), `< 5,000 ms` (`R07`, `R08`) |
| **P5** | **Sub-second order placement & dispatch loop:** Placing new orders (`W01`), polling unassigned orders waiting for a rider (`R12`), assigning riders (`W02`), and flagging orders stuck in `PREPARING` > 40 mins (`R05`) execute continuously every few seconds. | Customers, Dispatch / Ops Team, Delivery Partners | `R05`, `R12`, `W01`, `W02` | **Customer-facing & Ops / Real-time OLTP** | `< 5 ms` |
| **P6** | **Accurate rider earnings & idle-fleet tracking:** Riders need instant weekly earnings (`R11`), and the Fleet team needs an accurate list of active riders with no recent assignments (`R13` — currently returning 0 rows due to `NOT IN` with `NULL` `partner_id` values). | Delivery Partners, Fleet Team | `R11`, `R13` | **Real-time Partner App** (`R11`) & **Interactive Ops** (`R13`) | `< 5 ms` (`R11`), `< 250 ms` (`R13`) |
| **P7** | **Near-real-time payment failure & fraud monitoring:** Payments and Risk teams must track recent failed payment attempts by method (`R16`) and identify customers with repeated payment failures (`R17`). | Payments Team, Risk / Fraud Team | `R16`, `R17` | **Interactive Ops** (`R16`) & **Reporting / Analytics** (`R17`) | `< 250 ms` (`R16`), `< 5,000 ms` (`R17`) |
| **P8** | **Subscription retention, coupon ROI & cohort growth:** Marketing and Gold teams need targeted lists of expiring Gold members who are still active (`R14`), nightly expiration batch updates (`W05`), coupon ROI (`R15`), top spenders (`R20`), and city repeat-order rates (`R21`). | Gold Team, Marketing / Growth Team | `R14`, `R15`, `R20`, `R21`, `W05` | **Interactive Ops** (`R14`), **Reporting / Analytics** (`R15`, `R20`, `R21`), **Batch Job** (`W05`) | `< 250 ms` (`R14`), `< 5,000 ms` (`R15`, `R20`, `R21`), `< 2,000 ms` (`W05`) |
| **P9** | **Fast escalation of SLA breaches & negative reviews:** Support agents need rapid lookups of deliveries exceeding 60 minutes (`R10`) and newest reviews mentioning `"cold"` or `"late"` (`R18`). | Customer Support Team, Customers | `R10`, `R18` | **Interactive Support / Ops** | `< 250 ms` |
| **P10** | **Scalable leadership dashboards & nightly aggregations:** Leadership and Ops need city-level monthly delivery SLA trends (`R09`), restaurant health metrics (`R19`), hourly demand heatmaps (`R22`), deep admin order pagination (`R23`), and nightly rating recomputation (`W04`) that survive a 20× volume increase. | Leadership, Ops / Admin Team | `R09`, `R19`, `R22`, `R23`, `W04` | **Reporting / Analytics** (`R09`, `R19`, `R22`, `R23`) & **Batch Job** (`W04`) | `< 5,000 ms` (`R09`, `R19`, `R22`, `R23`), `< 2,000 ms` (`W04`) |

---

## 3. Key Assumptions
1. **Single-City Order Scope:** Every order occurs within a single city (the customer's city, restaurant's locality city, and assigned delivery partner's city match across all 150,000 seed orders).
2. **Time Zone Consistency:** All timestamps represent Indian Standard Time (`UTC+05:30`) and are stored as `TIMESTAMPTZ`.
3. **Currency & Precision:** All monetary figures (`price`, `item_total`, `delivery_fee`, `discount`, `total_amount`, `amount`) are in INR (`NUMERIC(10,2)`) and obey `total_amount = item_total + delivery_fee - discount`.
4. **Order Lifecycle Monotonicity:** Timestamps follow `placed_at <= accepted_at <= picked_up_at <= delivered_at`, and presence of lifecycle timestamps and `partner_id` strictly depends on `orders.status`.
5. **Read vs. Write Freshness:** Real-time customer/dispatch queries (`R01`, `R03–R06`, `R11–R12`, `R24`, `W01–W03`) must hit the primary OLTP instance with strict consistency, whereas heavy analytical queries (`R07–R09`, `R15`, `R17`, `R19–R22`) can tolerate read replicas or scheduled refreshes.
