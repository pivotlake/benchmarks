-- The 8 TPC-H tables, each adopting the parquet files in its directory under
-- {source} in place and sorted by its primary key (sort_by), the order
-- ../../lib/pivot-style.sh writes the shared files in. ./load substitutes
-- {source}.
CREATE TABLE lineitem (
    l_orderkey BIGINT,
    l_partkey BIGINT,
    l_suppkey BIGINT,
    l_linenumber INTEGER,
    l_quantity DECIMAL(15,2),
    l_extendedprice DECIMAL(15,2),
    l_discount DECIMAL(15,2),
    l_tax DECIMAL(15,2),
    l_returnflag VARCHAR,
    l_linestatus VARCHAR,
    l_shipdate DATE,
    l_commitdate DATE,
    l_receiptdate DATE,
    l_shipinstruct VARCHAR,
    l_shipmode VARCHAR,
    l_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/lineitem', sort_by = 'l_orderkey,l_linenumber');

CREATE TABLE orders (
    o_orderkey BIGINT,
    o_custkey BIGINT,
    o_orderstatus VARCHAR,
    o_totalprice DECIMAL(15,2),
    o_orderdate DATE,
    o_orderpriority VARCHAR,
    o_clerk VARCHAR,
    o_shippriority INTEGER,
    o_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/orders', sort_by = 'o_orderkey');

CREATE TABLE customer (
    c_custkey BIGINT,
    c_name VARCHAR,
    c_address VARCHAR,
    c_nationkey BIGINT,
    c_phone VARCHAR,
    c_acctbal DECIMAL(15,2),
    c_mktsegment VARCHAR,
    c_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/customer', sort_by = 'c_custkey');

CREATE TABLE part (
    p_partkey BIGINT,
    p_name VARCHAR,
    p_mfgr VARCHAR,
    p_brand VARCHAR,
    p_type VARCHAR,
    p_size INTEGER,
    p_container VARCHAR,
    p_retailprice DECIMAL(15,2),
    p_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/part', sort_by = 'p_partkey');

CREATE TABLE partsupp (
    ps_partkey BIGINT,
    ps_suppkey BIGINT,
    ps_availqty INTEGER,
    ps_supplycost DECIMAL(15,2),
    ps_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/partsupp', sort_by = 'ps_partkey,ps_suppkey');

CREATE TABLE supplier (
    s_suppkey BIGINT,
    s_name VARCHAR,
    s_address VARCHAR,
    s_nationkey BIGINT,
    s_phone VARCHAR,
    s_acctbal DECIMAL(15,2),
    s_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/supplier', sort_by = 's_suppkey');

CREATE TABLE nation (
    n_nationkey BIGINT,
    n_name VARCHAR,
    n_regionkey BIGINT,
    n_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/nation', sort_by = 'n_nationkey');

CREATE TABLE region (
    r_regionkey BIGINT,
    r_name VARCHAR,
    r_comment VARCHAR
) WITH (with_pre_existing_parquets = '{source}/region', sort_by = 'r_regionkey');
