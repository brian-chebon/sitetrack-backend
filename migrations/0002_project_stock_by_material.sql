-- Removing a material is refused while any project store still holds some.
-- Without this index that check reads every project_stock row.
CREATE INDEX project_stock_material_idx ON project_stock (material_id) WHERE quantity > 0;
