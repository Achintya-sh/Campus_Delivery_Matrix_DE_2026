-- =====================================================================
-- Phase 4: Indexes for Query Optimization (sql/05_indexes.sql)
-- Database: PostgreSQL 15+ (Schema: zomato)
-- Every index documents:
--   1. Which workload queries (R01–R25, W01–W05) it serves
--   2. Why this index type (B-tree, Partial, Covering/INCLUDE, GIN)
--      and column order (equality first, range/sort second, INCLUDE payload)
--      were chosen
-- =====================================================================

SET search_path TO zomato;

-- Enable pg_trgm extension for trigram GIN indexes on leading-wildcard ILIKE queries (R02, R18)
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA zomato;

-- ---------------------------------------------------------------------
-- 1. LOCALITIES INDEXES
-- ---------------------------------------------------------------------

-- Serves: R01 (WHERE l.locality_name = 'Koramangala')
-- Why: B-tree on equality column `locality_name` with `INCLUDE (locality_id)`
-- allows an instant Index Only Scan to resolve 'Koramangala' -> locality_id.
DROP INDEX IF EXISTS idx_localities_name_inc;
CREATE INDEX idx_localities_name_inc
    ON localities (locality_name)
    INCLUDE (locality_id);

-- ---------------------------------------------------------------------
-- 2. RESTAURANTS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R01 (WHERE locality_id = ? AND status = 'OPEN' ORDER BY rating DESC NULLS LAST)
--         R19, R22, R08 (JOIN restaurants ON locality_id)
--         R25 (WHERE l.city_id = 6 AND r.status = 'OPEN' ORDER BY rating DESC NULLS LAST)
-- Why: Composite B-tree with equality columns `(locality_id, status)` first and sort
-- column `rating DESC NULLS LAST` third, covering `(restaurant_id, name, cuisines, avg_cost_for_two)`.
DROP INDEX IF EXISTS idx_restaurants_loc_status_rating;
CREATE INDEX idx_restaurants_loc_status_rating
    ON restaurants (locality_id, status, rating DESC NULLS LAST)
    INCLUDE (restaurant_id, name, cuisines, avg_cost_for_two);

-- Serves: R25 (WHERE r.status = 'OPEN' AND 'Chinese' = ANY(r.cuisines))
-- Why: Partial GIN index on array column `cuisines` restricted to `status = 'OPEN'`
-- supports the array containment/ANY operator at scale while keeping the index compact.
DROP INDEX IF EXISTS idx_restaurants_cuisines_gin_open;
CREATE INDEX idx_restaurants_cuisines_gin_open
    ON restaurants USING gin (cuisines)
    WHERE status = 'OPEN';

-- ---------------------------------------------------------------------
-- 3. MENU_ITEMS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R03 (WHERE restaurant_id = 217 AND is_available ORDER BY category, is_bestseller DESC, item_name)
--         W03 (UPDATE menu_items SET is_available = FALSE WHERE restaurant_id = 217 AND category = 'Desserts')
-- Why: Partial composite B-tree filtered on `WHERE is_available = TRUE` with equality
-- column `restaurant_id` first, followed by exact sort keys `(category, is_bestseller DESC, item_name)`
-- and `INCLUDE (price, is_veg)` so R03 executes as a zero-sort Index Only Scan, plus a compact
-- B-tree on `(restaurant_id, category)` so W03 locates target rows via Index Scan in <0.2 ms.
DROP INDEX IF EXISTS idx_menu_items_rest_avail_sort;
CREATE INDEX idx_menu_items_rest_avail_sort
    ON menu_items (restaurant_id, category, is_bestseller DESC, item_name)
    INCLUDE (price, is_veg)
    WHERE is_available = TRUE;

DROP INDEX IF EXISTS idx_menu_items_rest_category;
CREATE INDEX idx_menu_items_rest_category
    ON menu_items (restaurant_id, category);

-- Serves: R02 (WHERE l.city_id = 1 AND m.is_available AND m.item_name ILIKE '%paneer%' ORDER BY m.price LIMIT 50)
-- Why: Partial trigram GIN index (`gin_trgm_ops`) on `item_name` for available items.
-- Standard B-tree cannot accelerate leading-wildcard `ILIKE '%paneer%'`; pg_trgm extracts 3-character
-- grams to turn a 50,000-row sequential scan into a sub-millisecond Bitmap Index Scan.
DROP INDEX IF EXISTS idx_menu_items_name_trgm_avail;
CREATE INDEX idx_menu_items_name_trgm_avail
    ON menu_items USING gin (item_name zomato.gin_trgm_ops)
    WHERE is_available = TRUE;

-- ---------------------------------------------------------------------
-- 4. CUSTOMERS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R14 (WHERE c.is_gold_member AND c.gold_expires_on < '2026-07-01')
--         W05 (UPDATE customers SET is_gold_member = FALSE WHERE is_gold_member AND gold_expires_on < '2026-07-01')
-- Why: Partial B-tree index indexing ONLY active Gold members (`WHERE is_gold_member = TRUE` — 15% of table),
-- ordered by range column `gold_expires_on` and covering `(customer_id, full_name)` for R14.
DROP INDEX IF EXISTS idx_customers_gold_expires_partial;
CREATE INDEX idx_customers_gold_expires_partial
    ON customers (gold_expires_on)
    INCLUDE (customer_id, full_name)
    WHERE is_gold_member = TRUE;

-- Serves: R20 (WHERE c.city_id = 2 ... GROUP BY c.customer_id, c.full_name)
--         R21 (JOIN customers c ON c.customer_id = may.customer_id GROUP BY c.city_id)
-- Why: Composite covering B-tree on `(city_id, customer_id) INCLUDE (full_name)` allows
-- fast city filtering for R20, while `idx_customers_id_city` covers customer->city lookups in R21.
DROP INDEX IF EXISTS idx_customers_city_id_inc;
CREATE INDEX idx_customers_city_id_inc
    ON customers (city_id, customer_id)
    INCLUDE (full_name);

DROP INDEX IF EXISTS idx_customers_id_city_inc;
CREATE INDEX idx_customers_id_city_inc
    ON customers (customer_id)
    INCLUDE (city_id);

-- ---------------------------------------------------------------------
-- 5. DELIVERY_PARTNERS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R13 (WHERE p.city_id = 1 AND p.status = 'ACTIVE')
-- Why: Partial covering B-tree on `(city_id, partner_id) INCLUDE (full_name, phone) WHERE status = 'ACTIVE'`
-- enables an Index Only Scan of active riders in Bengaluru for anti-join against recent orders.
DROP INDEX IF EXISTS idx_partners_city_active_inc;
CREATE INDEX idx_partners_city_active_inc
    ON delivery_partners (city_id, partner_id)
    INCLUDE (full_name, phone)
    WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- 6. ORDERS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R04 (WHERE o.customer_id = 1042 ORDER BY o.placed_at DESC LIMIT 10)
--         R14 (EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id AND o.placed_at >= ...))
-- Why: Equality column `customer_id` first, sort/range column `placed_at DESC` second,
-- with `INCLUDE (order_id, restaurant_id, status, total_amount)` so R04 and R14 execute via Index Only Scan.
DROP INDEX IF EXISTS idx_orders_customer_placed_desc_inc;
CREATE INDEX idx_orders_customer_placed_desc_inc
    ON orders (customer_id, placed_at DESC)
    INCLUDE (order_id, restaurant_id, status, total_amount);

-- Serves: R06 (WHERE restaurant_id = 217 AND placed_at >= '2026-06-15' AND placed_at < '2026-06-16' ORDER BY placed_at)
--         R19 (max(o.placed_at) per restaurant_id)
-- Why: Equality column `restaurant_id` first, range/sort column `placed_at` second,
-- covering `(order_id, status, item_total)` for zero-heap-fetch Index Only Scan on R06 and R19.
DROP INDEX IF EXISTS idx_orders_rest_placed_inc;
CREATE INDEX idx_orders_rest_placed_inc
    ON orders (restaurant_id, placed_at)
    INCLUDE (order_id, status, item_total);

-- Serves: R07 (WHERE o.restaurant_id = 217 AND o.status = 'DELIVERED' AND o.placed_at >= ... AND o.placed_at < ...)
--         R08 (WHERE l.city_id = 6 AND o.status = 'DELIVERED' AND o.placed_at >= '2026-06-01')
--         R19 (count(*) WHERE o.restaurant_id = r.restaurant_id AND o.status = 'DELIVERED')
-- Why: Partial covering B-tree restricted to `WHERE status = 'DELIVERED'`, keyed on
-- `(restaurant_id, placed_at) INCLUDE (order_id)`.
DROP INDEX IF EXISTS idx_orders_rest_placed_delivered_inc;
CREATE INDEX idx_orders_rest_placed_delivered_inc
    ON orders (restaurant_id, placed_at)
    INCLUDE (order_id)
    WHERE status = 'DELIVERED';

-- Serves: R05 (WHERE status = 'PREPARING' AND accepted_at < ... ORDER BY accepted_at)
-- Why: Partial covering B-tree restricted to the tiny active subset `WHERE status = 'PREPARING'` (37 rows out of 150,000!),
-- ordered by `accepted_at` and covering `(order_id, restaurant_id)`. Shrinks index size by >99.9%.
DROP INDEX IF EXISTS idx_orders_preparing_accepted_partial;
CREATE INDEX idx_orders_preparing_accepted_partial
    ON orders (accepted_at)
    INCLUDE (order_id, restaurant_id)
    WHERE status = 'PREPARING';

-- Serves: R12 (WHERE o.partner_id IS NULL AND o.status IN ('PLACED', 'ACCEPTED') ORDER BY o.placed_at LIMIT 50)
--         W02 (SELECT order_id FROM orders WHERE partner_id IS NULL AND status = 'ACCEPTED' ORDER BY placed_at LIMIT 1)
-- Why: Partial covering B-tree indexing ONLY unassigned orders in `('PLACED', 'ACCEPTED')` (75 rows out of 150,000!),
-- ordered by `placed_at` with `INCLUDE (order_id, restaurant_id, status)`. Eliminates sorting and full table scans for dispatch.
DROP INDEX IF EXISTS idx_orders_unassigned_dispatch_partial;
CREATE INDEX idx_orders_unassigned_dispatch_partial
    ON orders (placed_at)
    INCLUDE (order_id, restaurant_id, status)
    WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED');

-- Serves: R11 (WHERE partner_id = 150 AND status = 'DELIVERED' AND placed_at >= ... AND placed_at < ...)
-- Why: Partial covering B-tree for delivered orders keyed on `(partner_id, placed_at) INCLUDE (delivery_fee)`
-- so rider earnings queries run in <0.1 ms via Index Only Scan.
DROP INDEX IF EXISTS idx_orders_partner_placed_delivered_inc;
CREATE INDEX idx_orders_partner_placed_delivered_inc
    ON orders (partner_id, placed_at)
    INCLUDE (delivery_fee)
    WHERE status = 'DELIVERED';

-- Serves: R13 (WHERE o.partner_id = p.partner_id AND o.placed_at >= '2026-06-25')
-- Why: Partial B-tree on `(placed_at, partner_id) WHERE partner_id IS NOT NULL` lets R13 scan only the
-- narrow post-June-25 window of assigned orders via Index Only Scan.
DROP INDEX IF EXISTS idx_orders_placed_partner_notnull;
CREATE INDEX idx_orders_placed_partner_notnull
    ON orders (placed_at, partner_id)
    WHERE partner_id IS NOT NULL;

-- Serves: R15 (LEFT JOIN orders o ON o.coupon_code = c.coupon_code AND o.status = 'DELIVERED')
-- Why: Partial covering B-tree on `(coupon_code) INCLUDE (order_id, discount, total_amount)` restricted to
-- `WHERE coupon_code IS NOT NULL AND status = 'DELIVERED'` (~17.5k rows instead of 150k).
DROP INDEX IF EXISTS idx_orders_coupon_delivered_partial;
CREATE INDEX idx_orders_coupon_delivered_partial
    ON orders (coupon_code)
    INCLUDE (order_id, discount, total_amount)
    WHERE coupon_code IS NOT NULL AND status = 'DELIVERED';

-- Serves: R09 (WHERE o.status = 'DELIVERED' AND o.placed_at >= '2026-01-01' AND o.placed_at < '2027-01-01')
--         R10 (WHERE delivered_at - placed_at > interval '60 minutes' AND placed_at >= '2026-06-01' AND placed_at < '2026-07-01')
--         R21 (WHERE placed_at >= '2026-05-01' AND placed_at < '2026-06-01' GROUP BY customer_id)
--         R22 (WHERE o.placed_at >= TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '8 weeks')
--         R23 (ORDER BY placed_at DESC OFFSET 100000 LIMIT 25)
-- Why: B-tree ordered by `(placed_at DESC)` covering `(order_id, customer_id, restaurant_id, status, total_amount, delivered_at)`
-- satisfies time-range window scans (R09, R10, R21, R22) and ordered pagination (R23) via Index Only Scan without heap sorts.
DROP INDEX IF EXISTS idx_orders_placed_desc_covering;
CREATE INDEX idx_orders_placed_desc_covering
    ON orders (placed_at DESC)
    INCLUDE (order_id, customer_id, restaurant_id, status, total_amount, delivered_at);

-- Serves: R20 (WHERE c.city_id = 2 AND o.status = 'DELIVERED' GROUP BY c.customer_id)
-- Why: Partial covering B-tree on `(customer_id) INCLUDE (total_amount) WHERE status = 'DELIVERED'`
-- accelerates per-customer lifetime spend aggregation via Index Only Scan.
DROP INDEX IF EXISTS idx_orders_customer_delivered_spend;
CREATE INDEX idx_orders_customer_delivered_spend
    ON orders (customer_id)
    INCLUDE (total_amount)
    WHERE status = 'DELIVERED';

-- Serves: R17 (JOIN orders o ON o.order_id = p.order_id GROUP BY o.customer_id)
-- Why: Covering B-tree on `(order_id) INCLUDE (customer_id)` allows R17 to join failed payments
-- to orders via an Index Only Scan without fetching the wide orders heap pages.
DROP INDEX IF EXISTS idx_orders_id_customer_inc;
CREATE INDEX idx_orders_id_customer_inc
    ON orders (order_id)
    INCLUDE (customer_id);

-- ---------------------------------------------------------------------
-- 7. PAYMENTS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R24 (LEFT JOIN payments p ON p.order_id = o.order_id AND p.payment_status = 'SUCCESS')
-- Why: Foreign-key B-tree index on `(order_id, payment_status) INCLUDE (method)` eliminates the
-- 137,378-row Parallel Seq Scan on `payments` when opening a single order's bill page.
DROP INDEX IF EXISTS idx_payments_order_status_inc;
CREATE INDEX idx_payments_order_status_inc
    ON payments (order_id, payment_status)
    INCLUDE (method);

-- Serves: R16 (WHERE payment_status = 'FAILED' AND attempted_at >= '2026-06-24' GROUP BY method)
--         R17 (WHERE p.payment_status = 'FAILED' JOIN orders o ON o.order_id = p.order_id)
-- Why: Partial covering B-tree indexing ONLY failed payments (`WHERE payment_status = 'FAILED'` — ~5% of payments),
-- ordered by `(attempted_at) INCLUDE (method, order_id)` so both R16 and R17 execute as compact Index Only Scans.
DROP INDEX IF EXISTS idx_payments_failed_attempted_partial;
CREATE INDEX idx_payments_failed_attempted_partial
    ON payments (attempted_at)
    INCLUDE (method, order_id)
    WHERE payment_status = 'FAILED';

-- ---------------------------------------------------------------------
-- 8. REVIEWS INDEXES
-- ---------------------------------------------------------------------

-- Serves: R19 (SELECT round(avg(v.food_rating), 2) FROM reviews v WHERE v.restaurant_id = r.restaurant_id)
--         W04 (SELECT restaurant_id, round(avg(food_rating), 1), count(*) FROM reviews GROUP BY restaurant_id)
-- Why: Covering B-tree on `(restaurant_id) INCLUDE (food_rating)` turns R19's per-restaurant review
-- aggregation and W04's grouping into fast Index Only Scans without touching the wide `review_text` heap pages.
DROP INDEX IF EXISTS idx_reviews_restaurant_rating_inc;
CREATE INDEX idx_reviews_restaurant_rating_inc
    ON reviews (restaurant_id)
    INCLUDE (food_rating);

-- Serves: R18 (WHERE review_text ILIKE '%cold%' OR review_text ILIKE '%late%' ORDER BY created_at DESC LIMIT 50)
-- Why: Trigram GIN index on `review_text` accelerates leading-wildcard `ILIKE '%cold%'` and `ILIKE '%late%'`
-- lookups via Bitmap Index Scan instead of scanning all 39,186 text rows.
DROP INDEX IF EXISTS idx_reviews_text_trgm;
CREATE INDEX idx_reviews_text_trgm
    ON reviews USING gin (review_text zomato.gin_trgm_ops)
    WHERE review_text IS NOT NULL;

-- Update visibility maps and planner statistics so Index Only Scans are chosen immediately
VACUUM ANALYZE;
