-- The 5 Star Schema Benchmark tables, each adopting the parquet files in its
-- directory under {source} in place and sorted by its primary key (sort_by),
-- the order ../../lib/pivot-style.sh writes the shared files in. ./load
-- substitutes {source}.
CREATE TABLE lineorder (
    lo_orderkey BIGINT,
    lo_linenumber INTEGER,
    lo_custkey BIGINT,
    lo_partkey BIGINT,
    lo_suppkey BIGINT,
    lo_orderdate INTEGER,
    lo_orderpriority VARCHAR,
    lo_shippriority VARCHAR,
    lo_quantity INTEGER,
    lo_extendedprice INTEGER,
    lo_ordtotalprice INTEGER,
    lo_discount INTEGER,
    lo_revenue INTEGER,
    lo_supplycost INTEGER,
    lo_tax INTEGER,
    lo_commitdate INTEGER,
    lo_shipmode VARCHAR
) WITH (with_pre_existing_parquets = '{source}/lineorder', sort_by = 'lo_orderkey,lo_linenumber');

CREATE TABLE customer (
    c_custkey BIGINT,
    c_name VARCHAR,
    c_address VARCHAR,
    c_city VARCHAR,
    c_nation VARCHAR,
    c_region VARCHAR,
    c_phone VARCHAR,
    c_mktsegment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/customer', sort_by = 'c_custkey');

CREATE TABLE supplier (
    s_suppkey BIGINT,
    s_name VARCHAR,
    s_address VARCHAR,
    s_city VARCHAR,
    s_nation VARCHAR,
    s_region VARCHAR,
    s_phone VARCHAR
) WITH (with_pre_existing_parquets = '{source}/supplier', sort_by = 's_suppkey');

CREATE TABLE part (
    p_partkey BIGINT,
    p_name VARCHAR,
    p_mfgr VARCHAR,
    p_category VARCHAR,
    p_brand1 VARCHAR,
    p_color VARCHAR,
    p_type VARCHAR,
    p_size INTEGER,
    p_container VARCHAR
) WITH (with_pre_existing_parquets = '{source}/part', sort_by = 'p_partkey');

CREATE TABLE date (
    d_datekey INTEGER,
    d_date VARCHAR,
    d_dayofweek VARCHAR,
    d_month VARCHAR,
    d_year INTEGER,
    d_yearmonthnum INTEGER,
    d_yearmonth VARCHAR,
    d_daynuminweek INTEGER,
    d_daynuminmonth INTEGER,
    d_daynuminyear INTEGER,
    d_monthnuminyear INTEGER,
    d_weeknuminyear INTEGER,
    d_sellingseason VARCHAR,
    d_lastdayinweekfl INTEGER,
    d_lastdayinmonthfl INTEGER,
    d_holidayfl INTEGER,
    d_weekdayfl INTEGER
) WITH (with_pre_existing_parquets = '{source}/date', sort_by = 'd_datekey');
