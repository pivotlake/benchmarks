-- The 8 TPC-H tables as MergeTree, each ordered by its primary key, the order
-- the shared parquet files are sorted in (../pivot/create.sql). The types
-- match the parquet files (BIGINT keys, DECIMAL(15,2) money, DATE dates). The
-- settings load primary keys and column sizes when the server starts rather
-- than on the first query, so the cold timer doesn't catch it (as ClickBench
-- does).
CREATE OR REPLACE TABLE lineitem (
    l_orderkey Int64, l_partkey Int64, l_suppkey Int64, l_linenumber Int32,
    l_quantity Decimal(15,2), l_extendedprice Decimal(15,2),
    l_discount Decimal(15,2), l_tax Decimal(15,2),
    l_returnflag String, l_linestatus String,
    l_shipdate Date, l_commitdate Date, l_receiptdate Date,
    l_shipinstruct String, l_shipmode String, l_comment String
) ENGINE = MergeTree ORDER BY (l_orderkey, l_linenumber)
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE orders (
    o_orderkey Int64, o_custkey Int64, o_orderstatus String,
    o_totalprice Decimal(15,2), o_orderdate Date, o_orderpriority String,
    o_clerk String, o_shippriority Int32, o_comment String
) ENGINE = MergeTree ORDER BY o_orderkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE customer (
    c_custkey Int64, c_name String, c_address String, c_nationkey Int64,
    c_phone String, c_acctbal Decimal(15,2), c_mktsegment String, c_comment String
) ENGINE = MergeTree ORDER BY c_custkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE part (
    p_partkey Int64, p_name String, p_mfgr String, p_brand String, p_type String,
    p_size Int32, p_container String, p_retailprice Decimal(15,2), p_comment String
) ENGINE = MergeTree ORDER BY p_partkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE partsupp (
    ps_partkey Int64, ps_suppkey Int64, ps_availqty Int32,
    ps_supplycost Decimal(15,2), ps_comment String
) ENGINE = MergeTree ORDER BY (ps_partkey, ps_suppkey)
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE supplier (
    s_suppkey Int64, s_name String, s_address String, s_nationkey Int64,
    s_phone String, s_acctbal Decimal(15,2), s_comment String
) ENGINE = MergeTree ORDER BY s_suppkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE nation (
    n_nationkey Int64, n_name String, n_regionkey Int64, n_comment String
) ENGINE = MergeTree ORDER BY n_nationkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;

CREATE OR REPLACE TABLE region (
    r_regionkey Int64, r_name String, r_comment String
) ENGINE = MergeTree ORDER BY r_regionkey
    SETTINGS primary_key_lazy_load = 0, columns_and_secondary_indices_sizes_lazy_calculation = 0;
