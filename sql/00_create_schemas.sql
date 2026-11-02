CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS analytics;

COMMENT ON SCHEMA raw       IS 'Source files loaded as-is (all text). Never edited.';
COMMENT ON SCHEMA clean     IS 'Typed, translated and constrained version of raw.';
COMMENT ON SCHEMA analytics IS 'Feature tables and reporting views built from clean.';
