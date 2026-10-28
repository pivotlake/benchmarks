-- The 5 Star Schema Benchmark tables as MergeTree, each ordered by its primary
-- key, the order the shared parquet files are sorted in (../pivot/create.sql).
-- The types match the parquet files. The settings load primary keys and column
-- sizes when the server starts rather than on the first query, so the cold
-- timer doesn't catch it (as ClickBench does).
CREATE OR REPLACE TABLE lineorder (
    lo_orderkey Int64, lo_linenumber Int32, lo_custkey Int64, lo_partkey Int64,
    lo_suppkey Int64, lo_orderdate Int32, lo_orderpriority String,
    lo_shippriority String, lo_quantity Int32, lo_extendedprice Int32,
    lo_ordtotalprice Int32, lo_discount Int32, lo_revenue Int32,
    lo_supplycost Int32, lo_tax Int32, lo_commitdate Int32, lo_shipmode String
) ENGINE = MergeTree ORDER BY (lo_orderkey, lo_linenumber)
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE customer (
    c_custkey Int64, c_name String, c_address String, c_city String,
    c_nation String, c_region String, c_phone String, c_mktsegment String
) ENGINE = MergeTree ORDER BY c_custkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE supplier (
    s_suppkey Int64, s_name String, s_address String, s_city String,
    s_nation String, s_region String, s_phone String
) ENGINE = MergeTree ORDER BY s_suppkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE part (
    p_partkey Int64, p_name String, p_mfgr String, p_category String,
    p_brand1 String, p_color String, p_type String, p_size Int32, p_container String
) ENGINE = MergeTree ORDER BY p_partkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE date (
    d_datekey Int32, d_date String, d_dayofweek String, d_month String,
    d_year Int32, d_yearmonthnum Int32, d_yearmonth String, d_daynuminweek Int32,
    d_daynuminmonth Int32, d_daynuminyear Int32, d_monthnuminyear Int32,
    d_weeknuminyear Int32, d_sellingseason String, d_lastdayinweekfl Int32,
    d_lastdayinmonthfl Int32, d_holidayfl Int32, d_weekdayfl Int32
) ENGINE = MergeTree ORDER BY d_datekey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;
