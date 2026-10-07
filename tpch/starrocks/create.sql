-- The 8 TPC-H tables as StarRocks' own tables (the duplicate key model), each
-- sorted by its primary key, the order the shared parquet files are sorted in
-- (../pivot/create.sql), and hash-distributed on its first key column into
-- the number of buckets StarRocks picks. The types match the parquet files
-- (BIGINT keys, DECIMAL(15,2) money, DATE dates). One BE, so one replica.
CREATE TABLE lineitem (
    l_orderkey BIGINT, l_linenumber INT, l_partkey BIGINT, l_suppkey BIGINT,
    l_quantity DECIMAL(15,2), l_extendedprice DECIMAL(15,2),
    l_discount DECIMAL(15,2), l_tax DECIMAL(15,2),
    l_returnflag STRING, l_linestatus STRING,
    l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE,
    l_shipinstruct STRING, l_shipmode STRING, l_comment STRING
) DUPLICATE KEY (l_orderkey, l_linenumber) DISTRIBUTED BY HASH (l_orderkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE orders (
    o_orderkey BIGINT, o_custkey BIGINT, o_orderstatus STRING,
    o_totalprice DECIMAL(15,2), o_orderdate DATE, o_orderpriority STRING,
    o_clerk STRING, o_shippriority INT, o_comment STRING
) DUPLICATE KEY (o_orderkey) DISTRIBUTED BY HASH (o_orderkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE customer (
    c_custkey BIGINT, c_name STRING, c_address STRING, c_nationkey BIGINT,
    c_phone STRING, c_acctbal DECIMAL(15,2), c_mktsegment STRING, c_comment STRING
) DUPLICATE KEY (c_custkey) DISTRIBUTED BY HASH (c_custkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE part (
    p_partkey BIGINT, p_name STRING, p_mfgr STRING, p_brand STRING, p_type STRING,
    p_size INT, p_container STRING, p_retailprice DECIMAL(15,2), p_comment STRING
) DUPLICATE KEY (p_partkey) DISTRIBUTED BY HASH (p_partkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE partsupp (
    ps_partkey BIGINT, ps_suppkey BIGINT, ps_availqty INT,
    ps_supplycost DECIMAL(15,2), ps_comment STRING
) DUPLICATE KEY (ps_partkey, ps_suppkey) DISTRIBUTED BY HASH (ps_partkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE supplier (
    s_suppkey BIGINT, s_name STRING, s_address STRING, s_nationkey BIGINT,
    s_phone STRING, s_acctbal DECIMAL(15,2), s_comment STRING
) DUPLICATE KEY (s_suppkey) DISTRIBUTED BY HASH (s_suppkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE nation (
    n_nationkey BIGINT, n_name STRING, n_regionkey BIGINT, n_comment STRING
) DUPLICATE KEY (n_nationkey) DISTRIBUTED BY HASH (n_nationkey)
    PROPERTIES ("replication_num" = "1");

CREATE TABLE region (
    r_regionkey BIGINT, r_name STRING, r_comment STRING
) DUPLICATE KEY (r_regionkey) DISTRIBUTED BY HASH (r_regionkey)
    PROPERTIES ("replication_num" = "1");
