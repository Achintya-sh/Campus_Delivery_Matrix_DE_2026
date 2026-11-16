-- =====================================================================
-- Phase 2: Zomato Food Delivery Database Schema (sql/01_schema.sql)
-- Database: PostgreSQL 15+
-- Rules:
--   * All tables created inside schema `zomato`
--   * Only PK, FK, UNIQUE, NOT NULL, and CHECK constraints (no extra indexes)
-- =====================================================================

DROP SCHEMA IF EXISTS zomato CASCADE;
CREATE SCHEMA zomato;
SET search_path TO zomato;

-- 1. cities (10 rows in seed data)
CREATE TABLE cities (
    city_id     SMALLINT      PRIMARY KEY,
    city_name   VARCHAR(50)  NOT NULL UNIQUE,
    state       VARCHAR(50)  NOT NULL,
    CONSTRAINT chk_cities_id_pos CHECK (city_id > 0)
);

-- 2. localities (100 rows in seed data)
CREATE TABLE localities (
    locality_id   SMALLINT     PRIMARY KEY,
    city_id       SMALLINT     NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    locality_name VARCHAR(80)  NOT NULL,
    pincode       CHAR(6)      NOT NULL UNIQUE,
    CONSTRAINT uq_localities_city_name UNIQUE (city_id, locality_name),
    CONSTRAINT chk_localities_id_pos   CHECK (locality_id > 0),
    CONSTRAINT chk_localities_pincode  CHECK (pincode ~ '^[1-9][0-9]{5}$')
);

-- 3. customers (25,000 rows in seed data)
CREATE TABLE customers (
    customer_id     INTEGER      PRIMARY KEY,
    full_name       VARCHAR(100) NOT NULL,
    email           VARCHAR(120) NOT NULL UNIQUE,
    phone           CHAR(10)     NOT NULL UNIQUE,
    city_id         SMALLINT     NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    signup_date     DATE         NOT NULL,
    is_gold_member  BOOLEAN      NOT NULL DEFAULT FALSE,
    gold_expires_on DATE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_customers_id_pos     CHECK (customer_id > 0),
    CONSTRAINT chk_customers_phone      CHECK (phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT chk_customers_email      CHECK (email LIKE '%_@_%.__%'),
    CONSTRAINT chk_customers_gold_exp   CHECK (NOT is_gold_member OR gold_expires_on IS NOT NULL)
);

-- 4. restaurants (2,500 rows in seed data)
CREATE TABLE restaurants (
    restaurant_id    INTEGER       PRIMARY KEY,
    name             VARCHAR(120)  NOT NULL,
    locality_id      SMALLINT      NOT NULL REFERENCES localities(locality_id) ON DELETE RESTRICT,
    cuisines         TEXT[]        NOT NULL,
    avg_cost_for_two SMALLINT      NOT NULL,
    rating           NUMERIC(2, 1),
    rating_count     INTEGER       NOT NULL DEFAULT 0,
    opens_at         TIME          NOT NULL,
    closes_at        TIME          NOT NULL,
    is_pure_veg      BOOLEAN       NOT NULL DEFAULT FALSE,
    status           VARCHAR(25)   NOT NULL,
    onboarded_on     DATE          NOT NULL,
    CONSTRAINT chk_restaurants_id_pos       CHECK (restaurant_id > 0),
    CONSTRAINT chk_restaurants_cuisines     CHECK (cardinality(cuisines) >= 1),
    CONSTRAINT chk_restaurants_avg_cost     CHECK (avg_cost_for_two > 0),
    CONSTRAINT chk_restaurants_rating       CHECK (rating IS NULL OR (rating >= 1.0 AND rating <= 5.0)),
    CONSTRAINT chk_restaurants_rating_count CHECK (rating_count >= 0),
    CONSTRAINT chk_restaurants_hours        CHECK (opens_at < closes_at),
    CONSTRAINT chk_restaurants_status       CHECK (status IN ('OPEN', 'TEMPORARILY_CLOSED', 'DELISTED'))
);

-- 5. menu_items (50,000 rows in seed data)
CREATE TABLE menu_items (
    item_id       INTEGER        PRIMARY KEY,
    restaurant_id INTEGER        NOT NULL REFERENCES restaurants(restaurant_id) ON DELETE CASCADE,
    item_name     VARCHAR(120)   NOT NULL,
    category      VARCHAR(30)    NOT NULL,
    price         NUMERIC(8, 2)  NOT NULL,
    is_veg        BOOLEAN        NOT NULL DEFAULT TRUE,
    is_bestseller BOOLEAN        NOT NULL DEFAULT FALSE,
    is_available  BOOLEAN        NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_menu_items_id_pos   CHECK (item_id > 0),
    CONSTRAINT chk_menu_items_category CHECK (category IN ('Starters', 'Main Course', 'Breads', 'Rice', 'Desserts', 'Beverages')),
    CONSTRAINT chk_menu_items_price    CHECK (price > 0)
);

-- 6. delivery_partners (2,000 rows in seed data)
CREATE TABLE delivery_partners (
    partner_id   INTEGER       PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    phone        CHAR(10)      NOT NULL UNIQUE,
    city_id      SMALLINT      NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    vehicle_type VARCHAR(15)   NOT NULL,
    joined_on    DATE          NOT NULL,
    rating       NUMERIC(2, 1) NOT NULL,
    status       VARCHAR(15)   NOT NULL,
    CONSTRAINT chk_partners_id_pos   CHECK (partner_id > 0),
    CONSTRAINT chk_partners_phone    CHECK (phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT chk_partners_vehicle  CHECK (vehicle_type IN ('BIKE', 'SCOOTER', 'BICYCLE', 'EV')),
    CONSTRAINT chk_partners_rating   CHECK (rating >= 1.0 AND rating <= 5.0),
    CONSTRAINT chk_partners_status   CHECK (status IN ('ACTIVE', 'INACTIVE', 'BLOCKED'))
);

-- 7. coupons (30 rows in seed data)
CREATE TABLE coupons (
    coupon_code     VARCHAR(20)   PRIMARY KEY,
    discount_pct    SMALLINT      NOT NULL,
    max_discount    NUMERIC(8, 2) NOT NULL,
    min_order_value NUMERIC(8, 2) NOT NULL,
    valid_from      DATE          NOT NULL,
    valid_to        DATE          NOT NULL,
    CONSTRAINT chk_coupons_pct         CHECK (discount_pct > 0 AND discount_pct <= 100),
    CONSTRAINT chk_coupons_max_disc    CHECK (max_discount > 0),
    CONSTRAINT chk_coupons_min_order   CHECK (min_order_value > 0),
    CONSTRAINT chk_coupons_valid_dates CHECK (valid_from <= valid_to)
);

-- 8. orders (150,000 rows in seed data)
CREATE TABLE orders (
    order_id      BIGINT         PRIMARY KEY,
    customer_id   INTEGER        NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    restaurant_id INTEGER        NOT NULL REFERENCES restaurants(restaurant_id) ON DELETE RESTRICT,
    partner_id    INTEGER        REFERENCES delivery_partners(partner_id) ON DELETE RESTRICT,
    coupon_code   VARCHAR(20)    REFERENCES coupons(coupon_code) ON DELETE RESTRICT,
    placed_at     TIMESTAMPTZ    NOT NULL,
    accepted_at   TIMESTAMPTZ,
    picked_up_at  TIMESTAMPTZ,
    delivered_at  TIMESTAMPTZ,
    distance_km   NUMERIC(5, 2)  NOT NULL,
    item_total    NUMERIC(10, 2) NOT NULL,
    delivery_fee  NUMERIC(8, 2)  NOT NULL DEFAULT 0.00,
    discount      NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
    total_amount  NUMERIC(10, 2) NOT NULL,
    status        VARCHAR(30)    NOT NULL,
    CONSTRAINT chk_orders_id_pos          CHECK (order_id > 0),
    CONSTRAINT chk_orders_distance        CHECK (distance_km > 0 AND distance_km <= 50.0),
    CONSTRAINT chk_orders_amounts         CHECK (item_total > 0 AND delivery_fee >= 0 AND discount >= 0 AND total_amount >= 0),
    CONSTRAINT chk_orders_total_formula   CHECK (total_amount = item_total + delivery_fee - discount),
    CONSTRAINT chk_orders_coupon_discount CHECK ((discount = 0) OR (coupon_code IS NOT NULL)),
    CONSTRAINT chk_orders_status          CHECK (status IN (
        'PLACED', 'ACCEPTED', 'PREPARING', 'OUT_FOR_DELIVERY',
        'DELIVERED', 'CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_RESTAURANT'
    )),
    CONSTRAINT chk_orders_time_sequence   CHECK (
        (accepted_at  IS NULL OR accepted_at  >= placed_at) AND
        (picked_up_at IS NULL OR (accepted_at IS NOT NULL AND picked_up_at >= accepted_at)) AND
        (delivered_at IS NULL OR (picked_up_at IS NOT NULL AND delivered_at >= picked_up_at))
    ),
    CONSTRAINT chk_orders_status_lifecycle CHECK (
        (status = 'PLACED' AND partner_id IS NULL AND accepted_at IS NULL AND picked_up_at IS NULL AND delivered_at IS NULL) OR
        (status = 'ACCEPTED' AND partner_id IS NULL AND accepted_at IS NOT NULL AND picked_up_at IS NULL AND delivered_at IS NULL) OR
        (status = 'PREPARING' AND partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NULL AND delivered_at IS NULL) OR
        (status = 'OUT_FOR_DELIVERY' AND partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NOT NULL AND delivered_at IS NULL) OR
        (status = 'DELIVERED' AND partner_id IS NOT NULL AND accepted_at IS NOT NULL AND picked_up_at IS NOT NULL AND delivered_at IS NOT NULL) OR
        (status IN ('CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_RESTAURANT') AND picked_up_at IS NULL AND delivered_at IS NULL)
    )
);

-- 9. order_items (375,000 rows in seed data)
CREATE TABLE order_items (
    order_id   BIGINT        NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    item_id    INTEGER       NOT NULL REFERENCES menu_items(item_id) ON DELETE RESTRICT,
    quantity   SMALLINT      NOT NULL,
    unit_price NUMERIC(8, 2) NOT NULL,
    PRIMARY KEY (order_id, item_id),
    CONSTRAINT chk_order_items_quantity   CHECK (quantity > 0),
    CONSTRAINT chk_order_items_unit_price CHECK (unit_price > 0)
);

-- 10. payments (137,378 rows in seed data)
CREATE TABLE payments (
    payment_id     BIGINT         PRIMARY KEY,
    order_id       BIGINT         NOT NULL REFERENCES orders(order_id) ON DELETE RESTRICT,
    amount         NUMERIC(10, 2) NOT NULL,
    method         VARCHAR(15)    NOT NULL,
    payment_status VARCHAR(15)    NOT NULL,
    attempted_at   TIMESTAMPTZ    NOT NULL,
    CONSTRAINT chk_payments_id_pos     CHECK (payment_id > 0),
    CONSTRAINT chk_payments_amount     CHECK (amount > 0),
    CONSTRAINT chk_payments_method     CHECK (method IN ('UPI', 'CARD', 'WALLET', 'COD')),
    CONSTRAINT chk_payments_status     CHECK (payment_status IN ('SUCCESS', 'FAILED', 'REFUNDED')),
    CONSTRAINT chk_payments_cod_failed CHECK (NOT (method = 'COD' AND payment_status = 'FAILED'))
);

-- 11. reviews (39,186 rows in seed data)
CREATE TABLE reviews (
    review_id       INTEGER     PRIMARY KEY,
    order_id        BIGINT      NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE CASCADE,
    customer_id     INTEGER     NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    restaurant_id   INTEGER     NOT NULL REFERENCES restaurants(restaurant_id) ON DELETE RESTRICT,
    food_rating     SMALLINT    NOT NULL,
    delivery_rating SMALLINT,
    review_text     TEXT,
    created_at      TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_reviews_id_pos          CHECK (review_id > 0),
    CONSTRAINT chk_reviews_food_rating     CHECK (food_rating BETWEEN 1 AND 5),
    CONSTRAINT chk_reviews_delivery_rating CHECK (delivery_rating IS NULL OR (delivery_rating BETWEEN 1 AND 5))
);
