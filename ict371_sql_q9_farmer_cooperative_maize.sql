-- ============================================================================
-- ICT371 Advanced Database
-- Question 9: Farmer Cooperative Maize Deliveries (50 marks)
-- PostgreSQL Implementation
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS v_farmer_amount_due CASCADE;
DROP TABLE IF EXISTS daily_purchases CASCADE;
DROP TABLE IF EXISTS deliveries CASCADE;
DROP TABLE IF EXISTS farmers CASCADE;

-- ----------------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ----------------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value > 0),
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL CHECK (total_weight >= 0),
    total_value   NUMERIC(14, 2) NOT NULL CHECK (total_value >= 0)
);

-- ----------------------------------------------------------------------------
-- (b) Function: fn_maize_rate(p_grade) [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL.';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported maize grade (%): must be A, B, or C.', p_grade;
    END CASE;
END;
$$;

-- ----------------------------------------------------------------------------
-- (c) Procedure: pr_receive_delivery(p_farmer_id, p_grade, p_weight, p_date) [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     CHAR(1),
    p_weight    NUMERIC(10, 2),
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date (p_date) cannot be NULL.';
    END IF;

    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid delivery weight (%): must be greater than zero.', p_weight;
    END IF;

    -- Validate grade early; trigger computes and sets unit_rate and total_value
    PERFORM fn_maize_rate(p_grade);

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(TRIM(p_grade)), p_weight, p_date, FALSE);
END;
$$;

-- ----------------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on deliveries [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight_kg (%) must be positive.', NEW.weight_kg;
    END IF;

    NEW.grade       := UPPER(TRIM(NEW.grade));
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_deliveries_pricing();

-- ----------------------------------------------------------------------------
-- (a cont.) Seed 3 farmers and 6 deliveries covering all grades & payment states
-- ----------------------------------------------------------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-001', 'Ackson Tembo'),
    ('FRM-002', 'Beatrice Mbewe'),
    ('FRM-003', 'Collins Hachintu');

CALL pr_receive_delivery(1, 'A', 400.00, CURRENT_DATE - 3); -- K2,000.00
CALL pr_receive_delivery(1, 'B', 250.00, CURRENT_DATE - 1); -- K1,000.00
CALL pr_receive_delivery(2, 'C', 500.00, CURRENT_DATE - 2); -- K1,500.00
CALL pr_receive_delivery(2, 'A', 300.00, CURRENT_DATE - 1); -- K1,500.00
CALL pr_receive_delivery(3, 'B', 600.00, CURRENT_DATE - 2); -- K2,400.00
CALL pr_receive_delivery(3, 'C', 200.00, CURRENT_DATE);     -- K600.00

-- Mark Farmer 3's deliveries as paid so Farmer 3 tests the zero-due case in the view
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 3;
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id = 1;

-- ----------------------------------------------------------------------------
-- (e) View: v_farmer_amount_due [5 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value), 0.00) AS total_unpaid_value
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
      AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

SELECT * FROM v_farmer_amount_due;

-- ----------------------------------------------------------------------------
-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite B-tree index on (farmer_id, delivered_on) isolates
-- a specific farmer's rows and performs an ordered index scan between the two
-- delivery dates.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_delivered_on
    ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
  FROM deliveries
 WHERE farmer_id = 1
   AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- ----------------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_purchases(p_day) & pg_cron [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value  NUMERIC(14, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Purchase date (p_day) cannot be NULL.';
    END IF;

    SELECT COALESCE(SUM(weight_kg), 0.00),
           COALESCE(SUM(total_value), 0.00)
      INTO v_weight, v_value
      FROM deliveries
     WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);

COMMIT;

-- Schedule daily at 01:30 for the previous day
SELECT cron.schedule(
    'coop_daily_purchases_refresh',
    '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$
);
