-- The table of create.sql as a ClickHouse MergeTree: the same 26 columns, the
-- four documents as JSON, a partition a day. ./run.sh substitutes {sorted_by}
-- with the sort key of the layout it runs.
CREATE TABLE logs (
    timestamp      DateTime64(6, 'UTC'),
    minute         DateTime64(6, 'UTC'),
    deployment_id  String,
    cluster        String,
    namespace      String,
    service        String,
    pod            String,
    pod_uid        String,
    container      String,
    node           String,
    host_id        String,
    image          String,
    level          String,
    trace_id       String,
    span_id        String,
    message        String,
    body           String,
    body_length    UInt64,
    record_id      UInt64,
    pattern_id     UInt64,
    source         String,
    format         String,
    attributes     JSON,
    resource       JSON,
    measurements   JSON,
    labels         JSON
  )
  ENGINE = MergeTree
  PARTITION BY toDate(timestamp)
  ORDER BY ({sorted_by});
