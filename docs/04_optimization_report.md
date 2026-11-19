# Phase 4: Query Optimization Report (`docs/04_optimization_report.md`)

## 1. Executive Summary

- **Total Workload Execution Time (30 Queries):** Dropped from **`9,044.222 ms`** (Baseline) to **`205.512 ms`** (Optimized) — an overall improvement of **`97.73%` (`44.01×` speedup)**.
- **Read Workload (`R01`–`R25`):** Dropped from **`8,976.986 ms`** to **`152.895 ms`** (`98.30%` reduction, `58.71×` speedup).
- **Write Workload (`W01`–`W05`):** Dropped from **`67.236 ms`** to **`52.617 ms`** (`21.74%` reduction) because speeding up the `WHERE` subqueries in `W02`, `W03`, and `W05` outweighed index maintenance overhead on `W01` and `W04`.
- **Correctness Bug Found & Fixed (`R13`):** Identified and fixed the SQL three-valued logic `NULL` bug in `R13` (`NOT IN` over nullable `orders.partner_id` returned `0` rows instead of the actual `129` idle active Bengaluru delivery partners).

---

## 2. Complete 30-Query Optimization Table

$$	ext{Improvement \%} = \frac{\text{Before} - \text{After}}{\text{Before}} \times 100$$

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
| :--- | ---: | :--- | :--- | ---: | ---: | :---: |
| **R01** | 0.674 | Seq Scan on `restaurants` (2,500 rows) & `localities` (100 rows) + Sort on `rating DESC` | Composite covering B-tree `idx_restaurants_loc_status_rating (locality_id, status, rating DESC NULLS LAST) INCLUDE (...)` + `idx_localities_name_inc` (Index Only Scan, no Sort) | 0.261 | **61.3%** (2.6×) | ✅ |
| **R02** | 31.558 | Full Seq Scan on `menu_items` (50,000 rows) evaluating `ILIKE '%paneer%'` + Hash Join with `restaurants` & `localities` | Nested Loop Index Only Scan on `idx_restaurants_loc_status_rating` + Index Scan on `idx_menu_items_rest_category` (and trigram GIN `idx_menu_items_name_trgm_avail` for selective text queries) | 6.617 | **79.0%** (4.8×) | ✅ |
| **R03** | 3.945 | Full Seq Scan on `menu_items` (50,000 rows) + explicit Sort on `(category, is_bestseller DESC, item_name)` | Partial covering B-tree `idx_menu_items_rest_avail_sort (restaurant_id, category, is_bestseller DESC, item_name) INCLUDE (price, is_veg) WHERE is_available = TRUE` (zero-sort Index Only Scan) | 0.101 | **97.4%** (39.1×) | ✅ |
| **R04** | 11.104 | Parallel Seq Scan across all 150,000 `orders` rows + Top-N Sort for 1 customer's last 10 orders | Composite covering B-tree `idx_orders_customer_placed_desc_inc (customer_id, placed_at DESC) INCLUDE (order_id, restaurant_id, status, total_amount)` (10-row Index Only Scan) | 0.206 | **98.1%** (53.9×) | ✅ |
| **R05** | 12.035 | Parallel Seq Scan across all 150,000 `orders` rows to find 22 stuck `PREPARING` orders | Partial covering B-tree `idx_orders_preparing_accepted_partial (accepted_at) INCLUDE (order_id, restaurant_id) WHERE status = 'PREPARING'` (16 kB index, Index Only Scan) | 0.135 | **98.9%** (89.1×) | ✅ |
| **R06** | 8.678 | Non-sargable `DATE(placed_at) = '2026-06-15'` forced a Parallel Seq Scan of 150,000 `orders` rows | Query rewrite to sargable timestamp range `placed_at >= '2026-06-15' AND placed_at < '2026-06-16'` + covering B-tree `idx_orders_rest_placed_inc` (1-row Index Only Scan) | 0.128 | **98.5%** (67.8×) | ✅ |
| **R07** | 10.966 | Parallel Seq Scan of 150,000 `orders` rows to find May 2026 delivered orders for restaurant 217 | Partial covering B-tree `idx_orders_rest_placed_delivered_inc (restaurant_id, placed_at) INCLUDE (order_id) WHERE status = 'DELIVERED'` (Index Only Scan into Nested Loop) | 0.302 | **97.2%** (36.3×) | ✅ |
| **R08** | 12.508 | Seq Scan on 150,000 `orders` rows + Hash Join with `restaurants` and `localities` | Index Only Scan on `idx_restaurants_loc_status_rating` (Pune restaurants) driving Nested Loop Index Only Scan on `idx_orders_rest_placed_delivered_inc` | 9.029 | **27.8%** (1.4×) | ✅ |
| **R09** | 46.048 | Non-sargable `EXTRACT(YEAR FROM o.placed_at) = 2026` forced full Seq Scan of all 150,000 `orders` rows (2025 + 2026) | Query rewrite to sargable range `o.placed_at >= '2026-01-01' AND o.placed_at < '2027-01-01'` + Index Only Scan on `idx_orders_placed_desc_covering` (scans only 2026 half of table) | 42.002 | **8.8%** (1.1×) | ✅ |
| **R10** | 9.167 | Parallel Seq Scan of all 150,000 `orders` rows to inspect June 2026 delivery durations | Index Only Scan on `idx_orders_placed_desc_covering (placed_at DESC) INCLUDE (order_id, customer_id, restaurant_id, status, total_amount, delivered_at)` for June 2026 range | 1.510 | **83.5%** (6.1×) | ✅ |
| **R11** | 10.552 | Parallel Seq Scan of 150,000 `orders` rows to sum 1 week of fees for partner 150 | Partial covering B-tree `idx_orders_partner_placed_delivered_inc (partner_id, placed_at) INCLUDE (delivery_fee) WHERE status = 'DELIVERED'` (Index Only Scan) | 0.235 | **97.8%** (44.9×) | ✅ |
| **R12** | 17.034 | Full Seq Scan + Top-N Sort across 150,000 `orders` rows to find 75 unassigned `PLACED`/`ACCEPTED` orders | Partial covering B-tree `idx_orders_unassigned_dispatch_partial (placed_at) INCLUDE (order_id, restaurant_id, status) WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED')` (16 kB index, zero-sort Index Only Scan) | 0.156 | **99.1%** (109.2×) | ✅ |
| **R13** | 13.713 | Seq Scan on `orders` & `delivery_partners` + **WRONG RESULT (0 rows)** because `NOT IN` encountered `NULL` `orders.partner_id` | Query rewrite replacing `NOT IN` with `NOT EXISTS` anti-join + partial covering indexes `idx_partners_city_active_inc` & `idx_orders_placed_partner_notnull` (**Fixed: returns 129 idle active Bengaluru riders**) | 0.651 | **95.3%** (21.1×) | 🔧 Fixed (`0 → 129` rows) |
| **R14** | 15.960 | Full Seq Scans on `customers` (25,000 rows) and `orders` (150,000 rows) in Hash Semi Join | Partial covering B-tree `idx_customers_gold_expires_partial WHERE is_gold_member = TRUE` + `idx_orders_placed_desc_covering` (Index Only Scans on both sides of Semi Join) | 1.694 | **89.4%** (9.4×) | ✅ |
| **R15** | 32.489 | Full Seq Scan of all 150,000 `orders` rows to aggregate 17,500 coupon orders | Partial covering B-tree `idx_orders_coupon_delivered_partial (coupon_code) INCLUDE (order_id, discount, total_amount) WHERE coupon_code IS NOT NULL AND status = 'DELIVERED'` (Index Only Scan) | 5.763 | **82.3%** (5.6×) | ✅ |
| **R16** | 9.638 | Parallel Seq Scan across all 137,378 `payments` rows to find last 7 days of `FAILED` attempts | Partial covering B-tree `idx_payments_failed_attempted_partial (attempted_at) INCLUDE (method, order_id) WHERE payment_status = 'FAILED'` (Index Only Scan) | 0.329 | **96.6%** (29.3×) | ✅ |
| **R17** | 32.470 | Full Seq Scans on both `payments` (137,378 rows) and `orders` (150,000 rows) | Partial covering B-tree `idx_payments_failed_attempted_partial` (scans only 6,965 failed payments instead of 137,378 total payments) | 22.986 | **29.2%** (1.4×) | ✅ |
| **R18** | 26.129 | Full Seq Scan on `reviews` (39,186 rows) for leading-wildcard `ILIKE '%cold%' OR ILIKE '%late%'` + Sort | Query rewrite using disjoint `UNION ALL` branches + trigram GIN index `idx_reviews_text_trgm` (`pg_trgm`, Bitmap Index Scan) | 4.826 | **81.5%** (5.4×) | ✅ |
| **R19** | 8492.450 | **8,492.450 ms bottleneck:** 3 correlated subqueries executed 400 times (once per Bengaluru restaurant) doing 1,200 unindexed Seq Scans on `orders` and `reviews` | Query rewrite converting correlated subqueries into pre-aggregated `LEFT JOIN`s scoped to Bengaluru restaurants + Index Only Scans on `idx_orders_rest_placed_inc` & `idx_reviews_restaurant_rating_inc` | 26.455 | **99.7%** (321.0×) | ✅ |
| **R20** | 40.141 | Full Seq Scans on `orders` (150,000 rows) and `customers` (25,000 rows) + Hash Join | Covering Index Only Scans on `idx_customers_city_id_inc (city_id, customer_id) INCLUDE (full_name)` and `idx_orders_customer_delivered_spend (customer_id) INCLUDE (total_amount) WHERE status = 'DELIVERED'` | 15.412 | **61.6%** (2.6×) | ✅ |
| **R21** | 23.420 | Full Seq Scan of 150,000 `orders` rows to extract May 2026 orders + Seq Scan of `customers` | Index Only Scan on `idx_orders_placed_desc_covering` for May 2026 range (scans only ~8,300 May index entries instead of 150,000 heap rows) | 8.942 | **61.8%** (2.6×) | ✅ |
| **R22** | 29.746 | Full Seq Scan of 150,000 `orders` rows + Hash Join with `restaurants` and `localities` | Index Only Scan on `idx_restaurants_loc_status_rating` (Bengaluru restaurants) + Index Only Scan on `idx_orders_rest_placed_inc` for the 8-week window | 4.490 | **84.9%** (6.6×) | ✅ |
| **R23** | 74.508 | Full Seq Scan of 150,000 `orders` rows + top-N sort of 100,025 rows for `OFFSET 100000 LIMIT 25` | Query rewrite from `OFFSET 100000` to keyset (seek) pagination `WHERE placed_at < '2025-07-02 00:00:00+05:30' ORDER BY placed_at DESC LIMIT 25` + `idx_orders_placed_desc_covering` (25-row Index Only Scan) | 0.216 | **99.7%** (344.9×) | ✅ |
| **R24** | 11.434 | Parallel Seq Scan across all 137,378 `payments` rows to find the payment for `order_id = 123457` | Covering B-tree `idx_payments_order_status_inc (order_id, payment_status) INCLUDE (method)` (1-row Index Only Scan on `payments`) | 0.325 | **97.2%** (35.2×) | ✅ |
| **R25** | 0.619 | Seq Scan on `restaurants` (2,500 rows) + Sort on `rating DESC NULLS LAST` | Covering B-tree `idx_restaurants_loc_status_rating (locality_id, status, rating DESC NULLS LAST) INCLUDE (...)` (Index Only Scan) | 0.220 | **64.5%** (2.8×) | ✅ |
| **W01** | 1.507 | Single-row `INSERT INTO orders` (baseline had no secondary indexes on `orders`) | Maintains 11 secondary indexes on `orders` (only 7 non-partial/applicable indexes updated for a `PLACED` order; adds +0.376 ms, still 1.883 ms < 5 ms target) | 1.883 | -25.0% (0.80×) | ✅ |
| **W02** | 17.305 | Subquery `WHERE partner_id IS NULL AND status = 'ACCEPTED' ORDER BY placed_at LIMIT 1` did a full Seq Scan + Sort of 150,000 `orders` rows | Partial covering index `idx_orders_unassigned_dispatch_partial` finds the oldest `ACCEPTED` order in 1 index lookup (<0.05 ms) + updates 1 row | 1.003 | **94.2%** (17.3×) | ✅ |
| **W03** | 3.443 | Full Seq Scan across 50,000 `menu_items` rows to update `restaurant_id = 217 AND category = 'Desserts'` | Composite B-tree `idx_menu_items_rest_category (restaurant_id, category)` locates the 3 dessert items directly via Index Scan | 0.355 | **89.7%** (9.7×) | ✅ |
| **W04** | 19.338 | Nightly full-table rating recomputation across all 39,186 `reviews` and 2,390 `restaurants` | Full-table batch update touches 95.6% of `restaurants` (2,390/2,500 rows), so maintaining `idx_restaurants_loc_status_rating` adds +9.58 ms (28.915 ms total, well under 2,000 ms batch target) | 28.915 | -49.5% (0.67×) | ✅ |
| **W05** | 25.643 | Full Seq Scan across all 25,000 `customers` rows to expire 1,923 Gold memberships | Partial B-tree `idx_customers_gold_expires_partial (gold_expires_on) WHERE is_gold_member = TRUE` turns a full-table scan into a selective Bitmap Index Scan | 20.461 | **20.2%** (1.3×) | ✅ |
| **Total** | **9044.222** | **All 30 Queries Combined** | **24 targeted indexes + 6 query rewrites + `VACUUM ANALYZE`** | **205.608** | **97.73% (43.99×)** | **✅ (R13 fixed)** |

---

## 3. Wrong-Result Query Discovery & Fix (`R13`)

### 3.1 What Was Wrong in Original `R13`
In Phase 1 Problem `P6`, the Fleet team reported: *"The fleet team's idle-partner list came back empty, which can't be right."*
Original `R13`:
```sql
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND p.partner_id NOT IN (SELECT o.partner_id FROM orders o WHERE o.placed_at >= '2026-06-25');
```
### 3.2 Root Cause: SQL Three-Valued Logic (`NULL` inside `NOT IN`)
- In `orders`, unassigned orders (`PLACED`, `ACCEPTED`, `CANCELLED_BY_CUSTOMER`, `CANCELLED_BY_RESTAURANT`) have `partner_id IS NULL` (`13,538` rows total, including `75` orders placed on or after `2026-06-25`).
- In SQL, `x NOT IN (v1, v2, NULL)` expands to `(x <> v1) AND (x <> v2) AND (x <> NULL)`.
- Because `x <> NULL` evaluates to `UNKNOWN` (never `TRUE`), the entire `AND` conjunction evaluates to `FALSE` or `UNKNOWN` for **every single delivery partner**, causing `R13` to return **0 rows** (`actual rows=0` in `benchmarks/results/baseline/R13.txt`).

### 3.3 The Fix (`NOT EXISTS` Anti-Join)
Replacing `NOT IN` with `NOT EXISTS` (in `sql/06_optimized_queries.sql`) tests row existence under two-valued boolean semantics and uses our partial covering indexes `idx_partners_city_active_inc` and `idx_orders_placed_partner_notnull`:
```sql
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND NOT EXISTS (
      SELECT 1
      FROM orders o
      WHERE o.partner_id = p.partner_id
        AND o.placed_at >= '2026-06-25'
  );
```
- **Result Before Fix:** `0 rows` (`13.713 ms`)
- **Result After Fix:** **`129 rows`** (`0.651 ms` — `95.3%` faster and returns the exact 129 idle active Bengaluru riders!).

---

## 4. Proof That Rewritten Queries Return Unchanged Results

For every rewritten query (`R06`, `R09`, `R18`, `R19`, `R23`, plus `R13` verified against `NOT IN (... WHERE partner_id IS NOT NULL)`), we ran symmetric set-difference queries (`(Q_orig EXCEPT ALL Q_opt) UNION ALL (Q_opt EXCEPT ALL Q_orig)`) and row-count comparisons in PostgreSQL:

| Query | Rewrite Applied | Original Row Count | Optimized Row Count | `EXCEPT ALL` Symmetric Diff Rows | Result Verified? |
| :--- | :--- | ---: | ---: | ---: | :---: |
| **R06** | `DATE(placed_at) = '2026-06-15'` $\to$ sargable `TIMESTAMPTZ` range | `1` | `1` | **`0`** | ✅ Identical |
| **R09** | `EXTRACT(YEAR FROM o.placed_at) = 2026` $\to$ sargable `TIMESTAMPTZ` range | `60` | `60` | **`0`** | ✅ Identical |
| **R13** | `NOT IN` (with `NULL` bug) $\to$ `NOT EXISTS` (matches `NOT IN` with `WHERE partner_id IS NOT NULL`) | `0` (bug) / `129` (non-null) | `129` | **`0`** (vs non-null `NOT IN`) | 🔧 Bug Fixed (`129` rows) |
| **R18** | `ILIKE '%cold%' OR ILIKE '%late%'` $\to$ disjoint `UNION ALL` branches | `50` | `50` | **`0`** | ✅ Identical |
| **R19** | 3 correlated subqueries $\to$ pre-aggregated `LEFT JOIN`s over Bengaluru restaurants | `400` | `400` | **`0`** | ✅ Identical |
| **R23** | `OFFSET 100000 LIMIT 25` $\to$ keyset pagination `WHERE placed_at < '2025-07-02 00:00:00+05:30'` | `25` | `25` | **`0`** | ✅ Identical |

---

## 5. Before / After `EXPLAIN (ANALYZE, BUFFERS)` Plans for the 5 Biggest Improvements

### 5.1 Query `R23` — 74.508 ms → 0.216 ms (99.7% / 344.9× speedup)
- **Why it improved:** Replaced deep `OFFSET 100000` scan+sort with keyset pagination `WHERE placed_at < TIMESTAMPTZ '2025-07-02 00:00:00+05:30'` backed by covering index `idx_orders_placed_desc_covering`.

**Before (`baseline` Run 1):**
```text
Limit  (cost=21163.95..21164.01 rows=25 width=40) (actual time=65.450..65.459 rows=25.00 loops=1)
  Buffers: shared hit=2419, temp read=823 written=961
  ->  Sort  (cost=20913.95..21288.95 rows=150000 width=40) (actual time=55.436..62.171 rows=100025.00 loops=1)
        Sort Key: placed_at DESC
        Sort Method: external merge  Disk: 7664kB
        Buffers: shared hit=2419, temp read=823 written=961
        ->  Seq Scan on orders  (cost=0.00..3916.00 rows=150000 width=40) (actual time=0.012..19.252 rows=150000.00 loops=1)
              Buffers: shared hit=2416
Planning:
  Buffers: shared hit=92
Planning Time: 0.301 ms
Execution Time: 69.351 ms
```

**After (`optimized` Run 1):**
```text
Limit  (cost=0.42..1.72 rows=25 width=40) (actual time=0.443..0.448 rows=25.00 loops=1)
  Buffers: shared hit=2 read=2
  ->  Index Only Scan using idx_orders_placed_desc_covering on orders  (cost=0.42..2575.19 rows=49587 width=40) (actual time=0.443..0.445 rows=25.00 loops=1)
        Index Cond: (placed_at < '2025-07-02 00:00:00+05:30'::timestamp with time zone)
        Heap Fetches: 0
        Index Searches: 1
        Buffers: shared hit=2 read=2
Planning:
  Buffers: shared hit=359
Planning Time: 1.031 ms
Execution Time: 0.470 ms
```

### 5.2 Query `R19` — 8,492.450 ms → 26.455 ms (99.7% / 321.0× speedup)
- **Why it improved:** Replaced 3 per-restaurant correlated subqueries (which ran 1,200 unindexed Seq Scans on `orders` and `reviews`) with pre-aggregated `LEFT JOIN` subqueries scoped to Bengaluru restaurants and backed by `idx_orders_rest_placed_inc` and `idx_reviews_restaurant_rating_inc`.

**Before (`baseline` Run 1):**
```text
Sort  (cost=2461888.30..2461888.92 rows=250 width=67) (actual time=8539.360..8539.405 rows=400.00 loops=1)
  Sort Key: ((SubPlan 1)) DESC NULLS LAST
  Sort Method: quicksort  Memory: 49kB
  Buffers: shared hit=2092850
  ->  Hash Join  (cost=2.38..2461878.34 rows=250 width=67) (actual time=25.081..8538.993 rows=400.00 loops=1)
        Hash Cond: (r.locality_id = l.locality_id)
        Buffers: shared hit=2092847
        ->  Seq Scan on restaurants r  (cost=0.00..71.00 rows=2500 width=21) (actual time=0.004..0.378 rows=2500.00 loops=1)
              Buffers: shared hit=46
        ->  Hash  (cost=2.25..2.25 rows=10 width=2) (actual time=0.014..0.015 rows=10.00 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 9kB
              Buffers: shared hit=1
              ->  Seq Scan on localities l  (cost=0.00..2.25 rows=10 width=2) (actual time=0.007..0.011 rows=10.00 loops=1)
                    Filter: (city_id = 1)
                    Rows Removed by Filter: 90
                    Buffers: shared hit=1
        SubPlan 1
          ->  Aggregate  (cost=4291.16..4291.17 rows=1 width=8) (actual time=6.900..6.900 rows=1.00 loops=400)
                Buffers: shared hit=966400
                ->  Seq Scan on orders o  (cost=0.00..4291.00 rows=63 width=8) (actual time=0.375..6.891 rows=60.27 loops=400)
                      Filter: (restaurant_id = r.restaurant_id)
                      Rows Removed by Filter: 149940
                      Buffers: shared hit=966400
        SubPlan 2
          ->  Aggregate  (cost=4666.14..4666.15 rows=1 width=8) (actual time=12.330..12.330 rows=1.00 loops=400)
                Buffers: shared hit=966400
                ->  Seq Scan on orders o_1  (cost=0.00..4666.00 rows=54 width=0) (actual time=0.702..12.323 rows=52.38 loops=400)
                      Filter: ((restaurant_id = r.restaurant_id) AND ((status)::text = 'DELIVERED'::text))
                      Rows Removed by Filter: 149948
                      Buffers: shared hit=966400
        SubPlan 3
          ->  Aggregate  (cost=889.87..889.88 rows=1 width=32) (actual time=2.113..2.113 rows=1.00 loops=400)
                Buffers: shared hit=160000
                ->  Seq Scan on reviews v  (cost=0.00..889.83 rows=16 width=2) (actual time=0.201..2.107 rows=15.77 loops=400)
                      Filter: (restaurant_id = r.restaurant_id)
                      Rows Removed by Filter: 39170
                      Buffers: shared hit=160000
Planning:
  Buffers: shared hit=350
Planning Time: 0.992 ms
Execution Time: 8539.527 ms
```

**After (`optimized` Run 1):**
```text
Sort  (cost=2495.63..2496.25 rows=250 width=310) (actual time=56.722..56.740 rows=400.00 loops=1)
  Sort Key: (max(o.placed_at)) DESC NULLS LAST
  Sort Method: quicksort  Memory: 49kB
  Buffers: shared hit=1639 read=620
  CTE blr_rest
    ->  Nested Loop  (cost=0.28..47.92 rows=250 width=19) (actual time=0.060..0.141 rows=400.00 loops=1)
          Buffers: shared hit=27
          ->  Seq Scan on localities l  (cost=0.00..2.25 rows=10 width=2) (actual time=0.006..0.011 rows=10.00 loops=1)
                Filter: (city_id = 1)
                Rows Removed by Filter: 90
                Buffers: shared hit=1
          ->  Index Only Scan using idx_restaurants_loc_status_rating on restaurants r  (cost=0.28..4.32 rows=25 width=21) (actual time=0.007..0.010 rows=40.00 loops=10)
                Index Cond: (locality_id = l.locality_id)
                Heap Fetches: 0
                Index Searches: 10
                Buffers: shared hit=26
  ->  Hash Right Join  (cost=2366.53..2437.74 rows=250 width=310) (actual time=56.440..56.633 rows=400.00 loops=1)
        Hash Cond: (v.restaurant_id = b.restaurant_id)
        Buffers: shared hit=1636 read=620
        ->  HashAggregate  (cost=647.99..683.84 rows=2390 width=36) (actual time=5.044..5.162 rows=384.00 loops=1)
              Group Key: v.restaurant_id
              Batches: 1  Memory Usage: 129kB
              Buffers: shared hit=713 read=106
              ->  Nested Loop  (cost=0.29..627.50 rows=4099 width=6) (actual time=0.163..4.388 rows=6306.00 loops=1)
                    Buffers: shared hit=713 read=106
                    ->  CTE Scan on blr_rest b3  (cost=0.00..5.00 rows=250 width=4) (actual time=0.000..0.021 rows=400.00 loops=1)
                          Storage: Memory  Maximum Storage: 35kB
                    ->  Index Only Scan using idx_reviews_restaurant_rating_inc on reviews v  (cost=0.29..2.33 rows=16 width=6) (actual time=0.009..0.010 rows=15.77 loops=400)
                          Index Cond: (restaurant_id = b3.restaurant_id)
                          Heap Fetches: 0
                          Index Searches: 400
                          Buffers: shared hit=713 read=106
        ->  Hash  (cost=1715.41..1715.41 rows=250 width=278) (actual time=51.387..51.389 rows=400.00 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 36kB
              Buffers: shared hit=923 read=514
              ->  Hash Right Join  (cost=1656.15..1715.41 rows=250 width=278) (actual time=51.191..51.313 rows=400.00 loops=1)
                    Hash Cond: (o.restaurant_id = b.restaurant_id)
                    Buffers: shared hit=923 read=514
                    ->  HashAggregate  (cost=1648.02..1671.92 rows=2390 width=20) (actual time=50.946..50.996 rows=384.00 loops=1)
                          Group Key: o.restaurant_id
                          Batches: 1  Memory Usage: 121kB
                          Buffers: shared hit=896 read=514
                          ->  Nested Loop  (cost=0.42..1491.12 rows=15690 width=23) (actual time=0.167..48.284 rows=24106.00 loops=1)
                                Buffers: shared hit=896 read=514
                                ->  CTE Scan on blr_rest b2  (cost=0.00..5.00 rows=250 width=4) (actual time=0.000..0.038 rows=400.00 loops=1)
                                      Storage: Memory  Maximum Storage: 35kB
                                ->  Index Only Scan using idx_orders_rest_placed_inc on orders o  (cost=0.42..5.31 rows=63 width=23) (actual time=0.095..0.116 rows=60.27 loops=400)
                                      Index Cond: (restaurant_id = b2.restaurant_id)
                                      Heap Fetches: 46
                                      Index Searches: 400
                                      Buffers: shared hit=896 read=514
                    ->  Hash  (cost=5.00..5.00 rows=250 width=262) (actual time=0.236..0.237 rows=400.00 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 29kB
                          Buffers: shared hit=27
                          ->  CTE Scan on blr_rest b  (cost=0.00..5.00 rows=250 width=262) (actual time=0.062..0.209 rows=400.00 loops=1)
                                Storage: Memory  Maximum Storage: 35kB
                                Buffers: shared hit=27
Planning:
  Buffers: shared hit=729 read=3
Planning Time: 2.516 ms
Execution Time: 56.884 ms
```

### 5.3 Query `R12` — 17.034 ms → 0.156 ms (99.1% / 109.2× speedup)
- **Why it improved:** Created partial covering index `idx_orders_unassigned_dispatch_partial (placed_at) INCLUDE (order_id, restaurant_id, status) WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED')` (16 kB total size), turning a 150,000-row Seq Scan + Sort into a 50-row Index Only Scan.

**Before (`baseline` Run 1):**
```text
Limit  (cost=4291.06..4291.07 rows=5 width=31) (actual time=16.343..16.349 rows=50.00 loops=1)
  Buffers: shared hit=2419
  ->  Sort  (cost=4291.06..4291.07 rows=5 width=31) (actual time=16.343..16.345 rows=50.00 loops=1)
        Sort Key: placed_at
        Sort Method: quicksort  Memory: 30kB
        Buffers: shared hit=2419
        ->  Seq Scan on orders o  (cost=0.00..4291.00 rows=5 width=31) (actual time=16.294..16.319 rows=75.00 loops=1)
              Filter: ((partner_id IS NULL) AND ((status)::text = ANY ('{PLACED,ACCEPTED}'::text[])))
              Rows Removed by Filter: 149925
              Buffers: shared hit=2416
Planning:
  Buffers: shared hit=148
Planning Time: 0.369 ms
Execution Time: 16.371 ms
```

**After (`optimized` Run 1):**
```text
Limit  (cost=0.14..8.23 rows=6 width=31) (actual time=0.294..0.301 rows=50.00 loops=1)
  Buffers: shared hit=1 read=1
  ->  Index Only Scan using idx_orders_unassigned_dispatch_partial on orders o  (cost=0.14..8.23 rows=6 width=31) (actual time=0.294..0.297 rows=50.00 loops=1)
        Heap Fetches: 0
        Index Searches: 1
        Buffers: shared hit=1 read=1
Planning:
  Buffers: shared hit=400
Planning Time: 0.984 ms
Execution Time: 0.319 ms
```

### 5.4 Query `R05` — 12.035 ms → 0.135 ms (98.9% / 89.1× speedup)
- **Why it improved:** Created partial covering index `idx_orders_preparing_accepted_partial (accepted_at) INCLUDE (order_id, restaurant_id) WHERE status = 'PREPARING'` (16 kB total size), eliminating the Parallel Seq Scan over 150,000 orders.

**Before (`baseline` Run 1):**
```text
Gather Merge  (cost=4960.45..4963.53 rows=27 width=20) (actual time=11.302..12.531 rows=35.00 loops=1)
  Workers Planned: 1
  Workers Launched: 1
  Buffers: shared hit=2454
  ->  Sort  (cost=3960.44..3960.48 rows=16 width=20) (actual time=8.830..8.831 rows=17.50 loops=2)
        Sort Key: accepted_at
        Sort Method: quicksort  Memory: 25kB
        Buffers: shared hit=2454
        Worker 0:  Sort Method: quicksort  Memory: 25kB
        ->  Parallel Seq Scan on orders  (cost=0.00..3960.12 rows=16 width=20) (actual time=8.789..8.802 rows=17.50 loops=2)
              Filter: (((status)::text = 'PREPARING'::text) AND (accepted_at < ('2026-06-30 23:59:00+05:30'::timestamp with time zone - '00:40:00'::interval)))
              Rows Removed by Filter: 74982
              Buffers: shared hit=2416
Planning:
  Buffers: shared hit=94
Planning Time: 0.400 ms
Execution Time: 12.559 ms
```

**After (`optimized` Run 1):**
```text
Index Only Scan using idx_orders_preparing_accepted_partial on orders  (cost=0.14..12.70 rows=32 width=20) (actual time=0.218..0.226 rows=35.00 loops=1)
  Index Cond: (accepted_at < ('2026-06-30 23:59:00+05:30'::timestamp with time zone - '00:40:00'::interval))
  Heap Fetches: 6
  Index Searches: 1
  Buffers: shared hit=2 read=1
Planning:
  Buffers: shared hit=355
Planning Time: 1.306 ms
Execution Time: 0.245 ms
```

### 5.5 Query `R06` — 8.678 ms → 0.128 ms (98.5% / 67.8× speedup)
- **Why it improved:** Rewrote non-sargable `DATE(placed_at) = '2026-06-15'` into a sargable timestamp range `placed_at >= '2026-06-15 00:00:00+05:30' AND placed_at < '2026-06-16 00:00:00+05:30'` backed by covering index `idx_orders_rest_placed_inc`.

**Before (`baseline` Run 1):**
```text
Sort  (cost=4960.23..4960.23 rows=1 width=32) (actual time=7.722..8.622 rows=1.00 loops=1)
  Sort Key: placed_at
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=2419
  ->  Gather  (cost=1000.00..4960.22 rows=1 width=32) (actual time=7.477..8.606 rows=1.00 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=2416
        ->  Parallel Seq Scan on orders  (cost=0.00..3960.12 rows=1 width=32) (actual time=6.113..6.206 rows=0.50 loops=2)
              Filter: ((restaurant_id = 217) AND (date(placed_at) = '2026-06-15'::date))
              Rows Removed by Filter: 75000
              Buffers: shared hit=2416
Planning:
  Buffers: shared hit=103
Planning Time: 0.299 ms
Execution Time: 8.670 ms
```

**After (`optimized` Run 1):**
```text
Index Only Scan using idx_orders_rest_placed_inc on orders  (cost=0.42..8.44 rows=1 width=32) (actual time=0.217..0.217 rows=1.00 loops=1)
  Index Cond: ((restaurant_id = 217) AND (placed_at >= '2026-06-15 00:00:00+05:30'::timestamp with time zone) AND (placed_at < '2026-06-16 00:00:00+05:30'::timestamp with time zone))
  Heap Fetches: 0
  Index Searches: 1
  Buffers: shared hit=3 read=1
Planning:
  Buffers: shared hit=362
Planning Time: 0.986 ms
Execution Time: 0.237 ms
```

---

## 6. Write Overhead Analysis (`W01`–`W05`)

| Write Query | Operation | Before (ms) | After (ms) | Delta (ms) | Analysis & Acceptability |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **W01** | `INSERT INTO orders` (1 new `PLACED` row) | `1.507` | `1.883` | **`+0.376 ms`** (`+24.9%`) | **Acceptable:** Updating the applicable B-tree indexes on `orders` (note that partial indexes for `DELIVERED` and `PREPARING` are skipped automatically for a `PLACED` order!) adds only `0.376 ms`, keeping `W01` at `1.883 ms` (well below the `< 5 ms` real-time SLA). |
| **W02** | `UPDATE orders` (assign partner 150 to oldest `ACCEPTED` order) | `17.305` | `1.003` | **`-16.302 ms`** (`17.3×` faster) | **Net Speedup:** Although updating `partner_id` and `status` modifies index entries, the partial index `idx_orders_unassigned_dispatch_partial` eliminates the `17 ms` full table scan + sort in the `WHERE` subquery! |
| **W03** | `UPDATE menu_items` (hide desserts for restaurant 217) | `3.443` | `0.355` | **`-3.088 ms`** (`9.7×` faster) | **Net Speedup:** `idx_menu_items_rest_category` replaces a 50,000-row Seq Scan with a 3-row Index Scan, far outweighing the cost of removing 3 rows from `idx_menu_items_rest_avail_sort`. |
| **W04** | `UPDATE restaurants` (nightly rating recomputation from `reviews`) | `19.338` | `28.915` | **`+9.577 ms`** (`+49.5%`) | **Acceptable:** `W04` updates `rating` on `2,390` out of `2,500` restaurants (`95.6%` of the table), which requires updating `idx_restaurants_loc_status_rating` (since `rating` is a key column). An extra `9.58 ms` in a once-a-night batch job (`28.915 ms` vs `< 2,000 ms` target) is a negligible trade-off for sub-millisecond home-feed queries (`R01`, `R25`). |
| **W05** | `UPDATE customers` (nightly Gold membership expiration) | `25.643` | `20.461` | **`-5.182 ms`** (`20.2%` faster) | **Net Speedup:** Partial index `idx_customers_gold_expires_partial` allows PostgreSQL to jump directly to the `1,923` expired Gold members via Bitmap Index Scan instead of scanning all `25,000` customers. |

---

