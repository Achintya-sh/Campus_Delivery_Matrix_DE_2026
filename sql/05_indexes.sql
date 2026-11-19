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

