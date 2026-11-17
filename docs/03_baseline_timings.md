# Phase 3: Baseline Query Execution Timings (`docs/03_baseline_timings.md`)

## 1. Benchmark Environment & Methodology

- **Database Server:** PostgreSQL 18.6 (Postgres.app) on Apple M4 MacBook Pro (16 GB RAM)
- **Schema:** `zomato` (11 tables, 781,194 total seed rows, `ANALYZE` run after load, zero secondary indexes — only default `PRIMARY KEY` and `UNIQUE` indexes exist)
- **Measurement Method:** Every query in `queries/workload_30.sql` was executed **3 times** with `EXPLAIN (ANALYZE, BUFFERS)` via `./benchmarks/run_benchmark.sh campus_delivery_matrix baseline`. Write queries (`W01`–`W05`) ran inside `BEGIN; ... ROLLBACK;` so the dataset remained unchanged across all runs. All raw plans are stored in `benchmarks/results/baseline/R01.txt`–`W05.txt` and summarized in `benchmarks/results/baseline/summary.csv`.

---

## 2. Baseline Execution Timings (All 30 Queries)

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Home feed: open restaurants in Koramangala, best rated first | READ | 0.909 | 0.556 | 0.556 | 0.674 |
| R02: Dish search: available "paneer" dishes in Bengaluru | READ | 31.054 | 31.822 | 31.799 | 31.558 |
| R03: Restaurant page: the menu of one restaurant, grouped by category | READ | 4.535 | 3.726 | 3.575 | 3.945 |
| R04: "Your orders": a customer's last 10 orders with restaurant names | READ | 11.568 | 10.556 | 11.188 | 11.104 |
| R05: Kitchen-delay alert: orders stuck in PREPARING for over 40 minutes (checked at 23:59 on 30 Jun 2026) | READ | 12.559 | 12.041 | 11.506 | 12.035 |
| R06: Restaurant partner app: all orders received by restaurant 217 on 15 June 2026 | READ | 8.670 | 8.634 | 8.731 | 8.678 |
| R07: Restaurant partner app: units sold per dish in May 2026 | READ | 11.161 | 10.893 | 10.845 | 10.966 |
| R08: Bestseller badges: top 3 dishes of every Pune restaurant in the last 30 days | READ | 12.545 | 12.408 | 12.570 | 12.508 |
| R09: Ops dashboard: average delivery time (minutes) per city per month in 2026 | READ | 46.092 | 46.923 | 45.130 | 46.048 |
| R10: Customer support: deliveries in June 2026 that took more than 60 minutes | READ | 9.272 | 9.065 | 9.163 | 9.167 |
| R11: Delivery partner app: this week's earnings (delivery fees) for partner 150 | READ | 10.537 | 10.481 | 10.639 | 10.552 |
| R12: Dispatch: orders still waiting for a delivery partner, oldest first | READ | 16.371 | 17.266 | 17.466 | 17.034 |
| R13: Fleet team: active Bengaluru partners who have not been assigned any order since 25 June 2026 | READ | 12.799 | 14.067 | 14.273 | 13.713 |
| R14: Gold team: Gold members whose membership expires before July 2026 but who ordered in June 2026 | READ | 14.947 | 16.248 | 16.684 | 15.960 |
| R15: Marketing: coupon effectiveness (orders, total discount, average bill) | READ | 30.769 | 32.740 | 33.958 | 32.489 |
| R16: Payments team: failed payment attempts per method in the last 7 days | READ | 10.106 | 9.383 | 9.426 | 9.638 |
| R17: Risk team: customers with 2 or more failed payment attempts (all time) | READ | 31.173 | 33.496 | 32.742 | 32.470 |
| R18: Review moderation: newest reviews that complain about cold food or late delivery | READ | 26.249 | 26.028 | 26.111 | 26.129 |
| R19: Restaurant health report for Bengaluru: last order time, delivered orders and average food rating | READ | 8539.527 | 8403.653 | 8534.169 | 8492.450 |
| R20: Growth: top 20 customers in Mumbai by total spend on delivered orders | READ | 37.195 | 39.023 | 44.204 | 40.141 |
| R21: Growth: share of customers in each city who ordered at least twice in May 2026 | READ | 23.326 | 23.367 | 23.567 | 23.420 |
| R22: Ops heatmap: Bengaluru orders by weekday and hour, last 8 weeks | READ | 30.330 | 28.746 | 30.161 | 29.746 |
| R23: Admin panel: "All orders", newest first, page 4,001 (25 rows per page) | READ | 69.351 | 76.630 | 77.543 | 74.508 |
| R24: Bill page: one order with its items, restaurant and successful payment | READ | 10.953 | 11.677 | 11.671 | 11.434 |
| R25: Cuisine filter: open Chinese restaurants in Pune | READ | 0.638 | 0.587 | 0.631 | 0.619 |
| W01: Customer app: place a new order (header row) | WRITE | 2.049 | 1.162 | 1.311 | 1.507 |
| W02: Dispatch: assign partner 150 to the oldest accepted order that has no partner | WRITE | 17.161 | 17.139 | 17.614 | 17.305 |
| W03: Restaurant partner app: desserts sold out, so hide them | WRITE | 3.494 | 3.344 | 3.491 | 3.443 |
| W04: Nightly job: recompute every restaurant's rating from its reviews | WRITE | 18.942 | 19.302 | 19.771 | 19.338 |
| W05: Nightly job: end Gold membership for customers whose plan has expired | WRITE | 38.806 | 18.884 | 19.240 | 25.643 |
| **Total (sum of all 30)** | | **9093.088** | **8949.847** | **9089.735** | **9044.222** |

---

## 3. Scan Type & Performance Analysis per Query

| Query | Type | Average (ms) | Scan Type(s) from `EXPLAIN` Plan | Why It Is Slow or Fast |
| :--- | :---: | ---: | :--- | :--- |
| **R01** | READ | 0.674 | `Seq Scan on restaurants | Seq Scan on localities` | Fast (~0.67 ms) on seed data because `restaurants` (2,500 rows) and `localities` (100 rows) fit in memory, though both use unindexed Seq Scans + Hash Join. |
| **R02** | READ | 31.558 | `Seq Scan on menu_items | Seq Scan on restaurants | Seq Scan on localities` | Slow (~31.56 ms) because `menu_items` (50,000 rows) undergoes a full Seq Scan evaluating leading-wildcard `ILIKE '%paneer%'` without a trigram (GIN) or `(restaurant_id, is_available)` index. |
| **R03** | READ | 3.945 | `Seq Scan on menu_items` | Moderately fast (~3.95 ms) in memory, but performs a full Seq Scan across all 50,000 `menu_items` rows to find ~20 rows for `restaurant_id = 217` because `restaurant_id` is unindexed. |
| **R04** | READ | 11.104 | `Seq Scan on orders | Index Scan using restaurants_pkey on restaurants` | Slow for a point-lookup (~11.10 ms) because `orders` (150,000 rows) has no index on `(customer_id, placed_at DESC)`, forcing a Parallel Seq Scan of the entire `orders` table before probing `restaurants_pkey`. |
| **R05** | READ | 12.035 | `Seq Scan on orders` | Slow (~12.04 ms) for a real-time dispatch alert because `orders` lacks a partial index on `accepted_at WHERE status = 'PREPARING'`, forcing a Parallel Seq Scan of all 150,000 orders. |
| **R06** | READ | 8.678 | `Seq Scan on orders` | Slow (~8.68 ms) for a single-restaurant daily lookup: `orders` has no index on `restaurant_id` or `placed_at`, and `DATE(placed_at)` is non-sargable, causing a Parallel Seq Scan of 150,000 rows. |
| **R07** | READ | 10.966 | `Seq Scan on orders | Index Scan using order_items_pkey on order_items | Index Scan using menu_items_pkey on menu_items` | Moderately slow (~10.97 ms) because finding restaurant 217's May 2026 delivered orders requires a Parallel Seq Scan of 150,000 `orders` rows before Nested Loop Index Scans on `order_items_pkey` and `menu_items_pkey`. |
| **R08** | READ | 12.508 | `Seq Scan on orders | Seq Scan on restaurants | Seq Scan on localities | Index Scan using order_items_pkey on order_items` | Takes ~12.51 ms because `orders` (150,000 rows) is sequentially scanned to filter `status = 'DELIVERED'` and `placed_at >= '2026-06-01'`, joined with Pune restaurants, and then probes `order_items_pkey` before window ranking. |
| **R09** | READ | 46.048 | `Seq Scan on orders | Seq Scan on restaurants | Seq Scan on localities` | Slow (~46.05 ms) because `EXTRACT(YEAR FROM o.placed_at) = 2026` scans all 150,000 `orders` rows via Seq Scan and hashes them against `restaurants` and `localities` before grouping. |
| **R10** | READ | 9.167 | `Seq Scan on orders` | Takes ~9.17 ms due to a Parallel Seq Scan over 150,000 `orders` rows because there is no index on `placed_at` (or partial index for slow June deliveries). |
| **R11** | READ | 10.552 | `Seq Scan on orders` | Slow for a single-rider lookup (~10.55 ms) because `orders` has no index on `(partner_id, status, placed_at)`, scanning all 150,000 orders to find a handful of deliveries for partner 150. |
| **R12** | READ | 17.034 | `Seq Scan on orders` | Slow (~17.03 ms) for a high-frequency dispatch poll because `orders` has no partial index on `(placed_at) WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED')`, scanning 150,000 rows. |
| **R13** | READ | 13.713 | `Seq Scan on delivery_partners | Seq Scan on orders` | Takes ~13.71 ms via Seq Scans on `delivery_partners` and `orders` (hashed SubPlan), AND returns a wrong result (0 rows instead of 82) because `NOT IN` encounters `NULL` `partner_id` rows in `orders`. |
| **R14** | READ | 15.960 | `Seq Scan on orders | Seq Scan on customers` | Takes ~15.96 ms because both `customers` (25,000 rows) and `orders` (150,000 rows) are sequentially scanned in a Hash Semi Join with no index on `customers(gold_expires_on)` or `orders(customer_id, placed_at)`. |
| **R15** | READ | 32.489 | `Seq Scan on orders | Seq Scan on coupons` | Takes ~32.49 ms because aggregating coupon usage across all delivered orders requires a full Seq Scan of 150,000 `orders` rows and a Hash Right Join with `coupons`. |
| **R16** | READ | 9.638 | `Seq Scan on payments` | Takes ~9.64 ms because `payments` (137,378 rows) has no index on `(payment_status, attempted_at)` or partial index on `WHERE payment_status = 'FAILED'`, requiring a Parallel Seq Scan. |
| **R17** | READ | 32.470 | `Seq Scan on orders | Seq Scan on payments` | Slow (~32.47 ms) because `payments` (137,378 rows) and `orders` (150,000 rows) are both sequentially scanned and hash-joined to group failed attempts by `customer_id`. |
| **R18** | READ | 26.129 | `Seq Scan on reviews` | Slow (~26.13 ms) because `reviews` (39,186 rows) is sequentially scanned to evaluate two leading-wildcard `ILIKE` predicates (`%cold%` OR `%late%`) and then sorted by `created_at DESC`. |
| **R19** | READ | 8492.450 | `Seq Scan on restaurants | Seq Scan on localities | Seq Scan on orders | Seq Scan on reviews` | Extremely slow (~8,492.45 ms = 8.49 s, the bottleneck query) because 3 correlated subqueries (`max(placed_at)`, `count(*)` on `orders`, and `avg(food_rating)` on `reviews`) execute 250 times each (once per Bengaluru restaurant) using repeated unindexed Seq Scans over 150,000 `orders` and 39,186 `reviews`! |
| **R20** | READ | 40.141 | `Seq Scan on orders | Seq Scan on customers` | Slow (~40.14 ms) because `orders` (150,000 rows) and `customers` (25,000 rows) undergo full Seq Scans + Hash Join before aggregating spend for Mumbai customers. |
| **R21** | READ | 23.420 | `Seq Scan on customers | Seq Scan on orders` | Takes ~23.42 ms because scanning May 2026 orders and joining with 25,000 `customers` uses full Seq Scans on both tables. |
| **R22** | READ | 29.746 | `Seq Scan on orders | Seq Scan on restaurants | Seq Scan on localities` | Takes ~29.75 ms because `orders` (150,000 rows) is sequentially scanned and hash-joined with `restaurants` and `localities` to extract weekday/hour buckets for Bengaluru. |
| **R23** | READ | 74.508 | `Seq Scan on orders` | Very slow (~74.51 ms) because `ORDER BY placed_at DESC OFFSET 100000 LIMIT 25` without an index on `placed_at` forces a full Seq Scan of 150,000 `orders` and a sort of 100,025 rows. |
| **R24** | READ | 11.434 | `Index Scan using orders_pkey on orders | Index Scan using restaurants_pkey on restaurants | Seq Scan on payments | Index Scan using order_items_pkey on order_items | Index Scan using menu_items_pkey on menu_items` | Moderately slow (~11.43 ms) for a single-order bill lookup: `orders_pkey`, `restaurants_pkey`, `order_items_pkey`, and `menu_items_pkey` use fast Index Scans, but `payments` has no index on `order_id`, forcing a Parallel Seq Scan of all 137,378 `payments` rows! |
| **R25** | READ | 0.619 | `Seq Scan on restaurants | Seq Scan on localities` | Fast (~0.62 ms) on seed data because `restaurants` (2,500 rows) and `localities` (100 rows) are small, though both use unindexed Seq Scans (`'Chinese' = ANY(r.cuisines)` has no GIN index). |
| **W01** | WRITE | 1.507 | `(no scan)` | Fast (~1.51 ms) single-row `INSERT` into `orders`, validating PK, 4 FKs (`customers`, `restaurants`, `delivery_partners`, `coupons`), and CHECK constraints. |
| **W02** | WRITE | 17.305 | `Seq Scan on orders | Index Scan using orders_pkey on orders` | Slow (~17.31 ms) for a single-row dispatch assignment because the subquery finding the oldest `ACCEPTED` unassigned order performs a full Seq Scan + Sort over 150,000 `orders` before updating via `orders_pkey`. |
| **W03** | WRITE | 3.443 | `Seq Scan on menu_items` | Takes ~3.44 ms because `UPDATE menu_items WHERE restaurant_id = 217 AND category = 'Desserts'` must sequentially scan all 50,000 `menu_items` rows without an index on `(restaurant_id, category)`. |
| **W04** | WRITE | 19.338 | `Seq Scan on restaurants | Seq Scan on reviews` | Takes ~19.34 ms to sequentially scan all 39,186 `reviews`, hash-aggregate ratings by `restaurant_id`, and hash-join/update all 2,390 rated rows in `restaurants`. |
| **W05** | WRITE | 25.643 | `Seq Scan on customers` | Takes ~25.64 ms because `UPDATE customers` sequentially scans all 25,000 `customers` rows without a partial index on `(gold_expires_on) WHERE is_gold_member = TRUE` and updates 1,923 expired Gold members. |

---

## 4. Key Baseline Findings

1. **Primary Bottleneck (`R19` — 8,492.450 ms, 94.3% of total workload time):** `R19` executes three correlated subqueries per Bengaluru restaurant (`250` restaurants $\times$ `3` full table scans), scanning `orders` 500 times and `reviews` 250 times without foreign-key indexes.
2. **Unindexed Foreign Keys & Filter Columns on `orders` (150,000 rows) and `payments` (137,378 rows):** Even single-customer (`R04`), single-restaurant (`R06`), single-rider (`R11`), and single-bill (`R24` scanning all 137k `payments`) OLTP queries take `8–17 ms` due to Parallel/Seq Scans.
3. **Deep `OFFSET` Pagination (`R23` — 74.508 ms):** Scanning and sorting 100,025 rows to return 25 rows scales linearly $O(N)$ and will degrade severely at 20× volume.
4. **Wrong-Result Bug Caught in `R13`:** `R13` returns **0 rows** (`rows=0` in `benchmarks/results/baseline/R13.txt`) because `NOT IN (SELECT o.partner_id FROM orders o WHERE o.placed_at >= '2026-06-25')` encounters `NULL` values in `orders.partner_id` for unassigned orders.
