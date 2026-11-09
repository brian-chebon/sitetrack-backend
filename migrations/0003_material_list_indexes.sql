-- Indexes added after timing every screen against the seeded database
-- (tool/bench.dart; numbers in the README).

-- The company stock screen sorted by name pages through this index instead of
-- sorting all 20,000 names on every request (69 ms -> a few ms).
CREATE INDEX materials_name_order_idx ON materials (lower(name), id) WHERE deleted_at IS NULL;

-- Catalogue and stock searches match anywhere in a material's name
-- (`search=rebar`); trigrams let ILIKE '%rebar%' use an index.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX materials_name_trgm_idx ON materials USING gin (name gin_trgm_ops) WHERE deleted_at IS NULL;

-- The stock screen sorted by status (most urgent first) or by quantity walks
-- one of these instead of sorting every material. The CASE must match the
-- one in CompanyStoreRoutes exactly for the planner to use the index.
CREATE INDEX company_stock_urgency_idx ON company_stock (
  (CASE status WHEN 'out_of_stock' THEN 0 WHEN 'low_stock' THEN 1 ELSE 2 END), material_id);
CREATE INDEX company_stock_quantity_idx ON company_stock (quantity, material_id);
