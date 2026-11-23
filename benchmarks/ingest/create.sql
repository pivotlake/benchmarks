-- A table of logs as an observability pipeline writes them: 26 columns, four
-- of them VARIANT documents, partitioned by day. ./run.sh substitutes
-- {sorted_by} with the sort key of the layout it runs.
CREATE TABLE logs (
    "timestamp"    TIMESTAMP,
    minute         TIMESTAMP,
    deployment_id  VARCHAR,
    cluster        VARCHAR,
    namespace      VARCHAR,
    service        VARCHAR,
    pod            VARCHAR,
    pod_uid        VARCHAR,
    container      VARCHAR,
    node           VARCHAR,
    host_id        VARCHAR,
    image          VARCHAR,
    level          VARCHAR,
    trace_id       VARCHAR,
    span_id        VARCHAR,
    message        VARCHAR,
    body           VARCHAR,
    body_length    UBIGINT,
    record_id      UBIGINT,
    pattern_id     UBIGINT,
    source         VARCHAR,
    format         VARCHAR,
    attributes     VARIANT,
    resource       VARIANT,
    measurements   VARIANT,
    labels         VARIANT
  )
  PARTITIONED BY (day("timestamp"))
  SORTED BY ({sorted_by});
