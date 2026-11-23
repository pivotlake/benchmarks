//! Inserts synthetic log rows into a table at a fixed rate and meanwhile
//! runs one query again and again. Prints a line per insert and per query
//! run, then exits once its time is up.
//!
//! Each engine is fed the way its own clients feed it: pivot with `COPY ...
//! FROM STDIN` statements of Arrow IPC over the Postgres protocol,
//! ClickHouse with `INSERT` statements of RowBinary over HTTP, through its
//! official client. An insert is one statement either way, of the same rows.
//!
//! Every insert holds rows of every deployment, stamped with the time it is
//! sent, later rows later. The batches are generated once at startup, and an
//! insert only stamps one of them, so the loader takes little of the
//! machine the server shares with it.
//!
//! usage: logs-load --engine <pivot or clickhouse> --connection <where>
//!            --table <name> --inserts-per-second <number>
//!            --insert-bytes <Arrow bytes> --seconds <run time>
//!            [--connections <count, default 32>]
//!            [--query-file <path> --query-range-seconds <seconds, 0 for all>
//!             --query-pause-ms <milliseconds>]
//!
//! `--connection` is a Postgres connection string for pivot and the HTTP URL
//! of the server for ClickHouse. `--insert-bytes` sizes an insert by the
//! Arrow bytes of its rows for both, so both are sent the same rows.
//!
//! output:
//!   insert <started, unix seconds> <latency ms> <Arrow bytes> <rows, or ERROR and why>
//!   query <started, unix seconds> <latency ms> <rows, or ERROR and why>

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use arrow_array::{
    ArrayRef, RecordBatch, StringArray, TimestampMicrosecondArray, UInt64Array,
};
use arrow_ipc::writer::StreamWriter;
use arrow_schema::{Field, Schema, SchemaRef};
use futures::SinkExt;
use tokio_postgres::SimpleQueryMessage;

const DEPLOYMENT_COUNT: u64 = 200;
const CLUSTERS: [&str; 3] = ["prod-eu", "prod-us", "staging"];
const SERVICES: [&str; 24] = [
    "checkout", "cart", "payments", "catalog", "search", "recommendations", "auth", "gateway",
    "billing", "notifications", "inventory", "shipping", "frontend", "collector", "consumer",
    "scheduler", "reporting", "fraud", "ledger", "profile", "media", "ingress", "dns", "autoscaler",
];
const LEVELS: [(&str, u64); 4] = [("info", 70), ("warn", 12), ("error", 10), ("debug", 8)];
const MESSAGES: [&str; 12] = [
    "reconcile failed",
    "request completed",
    "failed to connect to upstream",
    "cache miss for key",
    "starting reconcile",
    "payment authorization declined",
    "slow query detected",
    "retrying after transient failure",
    "consumer lag above threshold",
    "token refreshed",
    "published event",
    "health check failed",
];
const ERRORS: [&str; 6] = [
    "context deadline exceeded while waiting for response headers",
    "connection reset by peer",
    "rpc error: code = Unavailable desc = upstream connect error or disconnect/reset before headers",
    "deadlock detected, process waits for ShareLock on transaction",
    "dial tcp 10.2.44.17:5432: connect: connection refused",
    "unexpected EOF reading response body",
];

/// The table's columns, in the order `CREATE TABLE` declares them.
const COLUMN_NAMES: [&str; 26] = [
    "timestamp", "minute", "deployment_id", "cluster", "namespace", "service", "pod", "pod_uid",
    "container", "node", "host_id", "image", "level", "trace_id", "span_id", "message", "body",
    "body_length", "record_id", "pattern_id", "source", "format", "attributes", "resource",
    "measurements", "labels",
];
const TIMESTAMP_COLUMN: usize = 0;
const MINUTE_COLUMN: usize = 1;

fn read_now_micros() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_micros() as i64
}

struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut value = self.0;
        value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        value ^ (value >> 31)
    }

    fn below(&mut self, bound: u64) -> u64 {
        self.next() % bound
    }

    fn pick<'a, T>(&mut self, values: &'a [T]) -> &'a T {
        &values[self.below(values.len() as u64) as usize]
    }

    fn hex(&mut self, digits: usize) -> String {
        let mut text = String::with_capacity(digits + 16);
        while text.len() < digits {
            text.push_str(&format!("{:016x}", self.next()));
        }
        text.truncate(digits);
        text
    }
}

/// What every row of one deployment shares.
struct Deployment {
    id: String,
    cluster: &'static str,
    namespace: String,
    service: &'static str,
    container: &'static str,
    image: String,
    pods: Vec<Pod>,
}

struct Pod {
    name: String,
    uid: String,
    node: String,
    host_id: String,
}

impl Deployment {
    fn build_all() -> Vec<Self> {
        let mut random = Random(0x5eed);
        (0..DEPLOYMENT_COUNT)
            .map(|index| {
                let service = SERVICES[index as usize % SERVICES.len()];
                let pods = (0..3 + random.below(6))
                    .map(|_| Pod {
                        name: format!("{service}-{}-{}", random.hex(10), random.hex(5)),
                        uid: random.hex(32),
                        node: format!("ip-10-2-{}-{}.internal", random.below(250), random.below(250)),
                        host_id: format!("i-{}", random.hex(17)),
                    })
                    .collect();
                Self {
                    id: format!("deployment-{index:04}"),
                    cluster: CLUSTERS[index as usize % CLUSTERS.len()],
                    namespace: format!("team-{}", index % 17),
                    service,
                    container: if index % 4 == 0 { "controller" } else { "app" },
                    image: format!("registry.example.com/{service}:1.{}.{}", index % 9, index % 5),
                    pods,
                }
            })
            .collect()
    }
}

/// The rows of one insert, held both ways they are sent: as Arrow columns,
/// in the table's column order, and row by row. Neither holds the two time
/// columns, which an insert stamps.
struct Batch {
    columns: Vec<ArrayRef>,
    rows: Vec<LogRow>,
}

/// One log row without its time columns, the documents as JSON text.
struct LogRow {
    deployment_id: String,
    cluster: &'static str,
    namespace: String,
    service: &'static str,
    pod: String,
    pod_uid: String,
    container: &'static str,
    node: String,
    host_id: String,
    image: String,
    level: &'static str,
    trace_id: String,
    span_id: String,
    message: &'static str,
    body: String,
    body_length: u64,
    record_id: u64,
    pattern_id: u64,
    attributes: String,
    resource: String,
    measurements: String,
    labels: String,
}

/// A log row as ClickHouse's client sends it: the table's columns in order,
/// the times as microseconds, the documents as JSON text the server parses.
#[derive(clickhouse::Row, serde::Serialize)]
struct ClickHouseLog<'a> {
    timestamp: i64,
    minute: i64,
    deployment_id: &'a str,
    cluster: &'a str,
    namespace: &'a str,
    service: &'a str,
    pod: &'a str,
    pod_uid: &'a str,
    container: &'a str,
    node: &'a str,
    host_id: &'a str,
    image: &'a str,
    level: &'a str,
    trace_id: &'a str,
    span_id: &'a str,
    message: &'a str,
    body: &'a str,
    body_length: u64,
    record_id: u64,
    pattern_id: u64,
    source: &'a str,
    format: &'a str,
    attributes: &'a str,
    resource: &'a str,
    measurements: &'a str,
    labels: &'a str,
}

impl LogRow {
    fn stamp(&self, timestamp: i64) -> ClickHouseLog<'_> {
        ClickHouseLog {
            timestamp,
            minute: timestamp - timestamp.rem_euclid(60_000_000),
            deployment_id: &self.deployment_id,
            cluster: self.cluster,
            namespace: &self.namespace,
            service: self.service,
            pod: &self.pod,
            pod_uid: &self.pod_uid,
            container: self.container,
            node: &self.node,
            host_id: &self.host_id,
            image: &self.image,
            level: self.level,
            trace_id: &self.trace_id,
            span_id: &self.span_id,
            message: self.message,
            body: &self.body,
            body_length: self.body_length,
            record_id: self.record_id,
            pattern_id: self.pattern_id,
            source: "kubernetes",
            format: "json",
            attributes: &self.attributes,
            resource: &self.resource,
            measurements: &self.measurements,
            labels: &self.labels,
        }
    }
}

fn build_strings<S: AsRef<str>>(values: &[S]) -> ArrayRef {
    Arc::new(StringArray::from_iter_values(values.iter().map(AsRef::as_ref)))
}

fn build_constant(value: &str, rows: usize) -> ArrayRef {
    Arc::new(StringArray::from_iter_values(std::iter::repeat_n(value, rows)))
}

fn build_variants<S: AsRef<str>>(documents: &[S]) -> ArrayRef {
    let documents = build_strings(documents);
    let variants = parquet_variant_compute::json_to_variant(&documents).unwrap();
    Arc::new(variants.into_inner())
}

/// The columns of `rows` rows drawn evenly from every deployment. The two
/// time columns are placeholders an insert overwrites.
fn generate_batch(deployments: &[Deployment], random: &mut Random, rows: usize) -> Batch {
    let mut log_rows = Vec::with_capacity(rows);
    let mut deployment_id = Vec::with_capacity(rows);
    let mut cluster = Vec::with_capacity(rows);
    let mut namespace = Vec::with_capacity(rows);
    let mut service = Vec::with_capacity(rows);
    let mut pod_name = Vec::with_capacity(rows);
    let mut pod_uid = Vec::with_capacity(rows);
    let mut container = Vec::with_capacity(rows);
    let mut node = Vec::with_capacity(rows);
    let mut host_id = Vec::with_capacity(rows);
    let mut image = Vec::with_capacity(rows);
    let mut level = Vec::with_capacity(rows);
    let mut trace_id = Vec::with_capacity(rows);
    let mut span_id = Vec::with_capacity(rows);
    let mut message = Vec::with_capacity(rows);
    let mut body = Vec::with_capacity(rows);
    let mut body_length = Vec::with_capacity(rows);
    let mut record_id = Vec::with_capacity(rows);
    let mut pattern_id = Vec::with_capacity(rows);
    let mut attributes = Vec::with_capacity(rows);
    let mut resource = Vec::with_capacity(rows);
    let mut measurements = Vec::with_capacity(rows);
    let mut labels = Vec::with_capacity(rows);
    for _ in 0..rows {
        let deployment = random.pick(deployments);
        let pod = random.pick(&deployment.pods);
        let mut level_pick = random.below(100);
        let mut row_level = LEVELS[0].0;
        for (name, weight) in LEVELS {
            if level_pick < weight {
                row_level = name;
                break;
            }
            level_pick -= weight;
        }
        let message_index = random.below(MESSAGES.len() as u64);
        let row_message = MESSAGES[message_index as usize];
        let error = random.pick(&ERRORS);
        let request_id = random.hex(32);
        let duration_ms = random.below(5_000) as f64 / 10.0;
        let object = format!("object-{}", random.below(5_000));
        // Squaring skews the choice, so a few tenants log most rows; a third
        // of the rows name none.
        let tenant_unit = random.below(1_000_000) as f64 / 1_000_000.0;
        let tenant_field = if random.below(3) == 0 {
            String::new()
        } else {
            format!("\"tenant\":\"tenant-{}\",", (tenant_unit * tenant_unit * 200.0) as u64)
        };
        let is_traced = random.below(10) < 3;

        let row_body = format!(
            "{{\"level\":\"{}\",\"logger\":\"{}\",\"message\":\"{row_message}\",\"controller\":\"{}.status\",\"name\":\"{object}\",\"request_id\":\"{request_id}\",\"duration_ms\":{duration_ms},\"error\":\"{error}\"}}",
            row_level.to_uppercase(),
            deployment.container,
            deployment.service,
        );
        let row_attributes = format!(
            "{{{tenant_field}\"controller\":\"{}.status\",\"error\":\"{error}\",\"logger\":\"{}\",\"name\":\"{object}\",\"request_id\":\"{request_id}\"}}",
            deployment.service, deployment.container,
        );
        let row_resource = format!(
            "{{\"container.image\":\"{}\",\"host.id\":\"{}\",\"host.name\":\"{}\",\"pod.uid\":\"{}\"}}",
            deployment.image, pod.host_id, pod.node, pod.uid,
        );

        let row_trace_id = if is_traced { random.hex(32) } else { String::new() };
        let row_span_id = if is_traced { random.hex(16) } else { String::new() };
        let row_record_id = random.next();
        let row_measurements = format!("{{\"duration_ms\":{duration_ms}}}");
        let row_labels = format!("{{\"cluster\":\"{}\",\"level\":\"{row_level}\"}}", deployment.cluster);
        log_rows.push(LogRow {
            deployment_id: deployment.id.clone(),
            cluster: deployment.cluster,
            namespace: deployment.namespace.clone(),
            service: deployment.service,
            pod: pod.name.clone(),
            pod_uid: pod.uid.clone(),
            container: deployment.container,
            node: pod.node.clone(),
            host_id: pod.host_id.clone(),
            image: deployment.image.clone(),
            level: row_level,
            trace_id: row_trace_id.clone(),
            span_id: row_span_id.clone(),
            message: row_message,
            body: row_body.clone(),
            body_length: (row_body.len() + row_attributes.len() + row_resource.len()) as u64,
            record_id: row_record_id,
            pattern_id: 2_241_814_617 + message_index,
            attributes: row_attributes.clone(),
            resource: row_resource.clone(),
            measurements: row_measurements.clone(),
            labels: row_labels.clone(),
        });

        deployment_id.push(deployment.id.as_str());
        cluster.push(deployment.cluster);
        namespace.push(deployment.namespace.as_str());
        service.push(deployment.service);
        pod_name.push(pod.name.as_str());
        pod_uid.push(pod.uid.as_str());
        container.push(deployment.container);
        node.push(pod.node.as_str());
        host_id.push(pod.host_id.as_str());
        image.push(deployment.image.as_str());
        level.push(row_level);
        trace_id.push(row_trace_id);
        span_id.push(row_span_id);
        message.push(row_message);
        body_length.push((row_body.len() + row_attributes.len() + row_resource.len()) as u64);
        body.push(row_body);
        record_id.push(row_record_id);
        pattern_id.push(2_241_814_617 + message_index);
        attributes.push(row_attributes);
        resource.push(row_resource);
        measurements.push(row_measurements);
        labels.push(row_labels);
    }
    let columns: Vec<ArrayRef> = vec![
        Arc::new(TimestampMicrosecondArray::from(vec![0i64; rows])),
        Arc::new(TimestampMicrosecondArray::from(vec![0i64; rows])),
        build_strings(&deployment_id),
        build_strings(&cluster),
        build_strings(&namespace),
        build_strings(&service),
        build_strings(&pod_name),
        build_strings(&pod_uid),
        build_strings(&container),
        build_strings(&node),
        build_strings(&host_id),
        build_strings(&image),
        build_strings(&level),
        build_strings(&trace_id),
        build_strings(&span_id),
        build_strings(&message),
        build_strings(&body),
        Arc::new(UInt64Array::from(body_length)),
        Arc::new(UInt64Array::from(record_id)),
        Arc::new(UInt64Array::from(pattern_id)),
        build_constant("kubernetes", rows),
        build_constant("json", rows),
        build_variants(&attributes),
        build_variants(&resource),
        build_variants(&measurements),
        build_variants(&labels),
    ];
    Batch { columns, rows: log_rows }
}

fn build_schema(columns: &[ArrayRef]) -> SchemaRef {
    Arc::new(Schema::new(
        COLUMN_NAMES
            .iter()
            .zip(columns)
            .map(|(name, column)| Field::new(*name, column.data_type().clone(), true))
            .collect::<Vec<_>>(),
    ))
}

fn encode_as_ipc(schema: &SchemaRef, columns: Vec<ArrayRef>) -> Vec<u8> {
    let batch = RecordBatch::try_new(schema.clone(), columns).unwrap();
    let mut writer = StreamWriter::try_new(Vec::new(), schema).unwrap();
    writer.write(&batch).unwrap();
    writer.finish().unwrap();
    writer.into_inner().unwrap()
}

/// The batches inserts are stamped from, each of about the Arrow bytes one
/// insert is to carry.
struct BatchPool {
    schema: SchemaRef,
    batches: Vec<Batch>,
    rows_per_batch: usize,
    /// The Arrow bytes of one batch, which an insert is counted as carrying
    /// however it is sent.
    bytes_per_batch: usize,
}

impl BatchPool {
    /// How many Arrow bytes of batches the pool holds at most.
    const POOL_BYTES: u64 = 256 << 20;
    const SAMPLE_ROWS: usize = 256;

    fn generate(insert_bytes: u64) -> Self {
        let deployments = Deployment::build_all();
        let mut random = Random(read_now_micros() as u64);
        let sample = generate_batch(&deployments, &mut random, Self::SAMPLE_ROWS).columns;
        let schema = build_schema(&sample);
        let empty = generate_batch(&deployments, &mut random, 0).columns;
        let empty_bytes = encode_as_ipc(&schema, empty).len();
        let sample_bytes = encode_as_ipc(&schema, sample).len();
        let bytes_per_row = (sample_bytes - empty_bytes) as f64 / Self::SAMPLE_ROWS as f64;
        let rows_per_batch =
            ((insert_bytes.saturating_sub(empty_bytes as u64)) as f64 / bytes_per_row).round().max(1.0) as usize;
        let batch_count = (Self::POOL_BYTES / insert_bytes.max(1)).clamp(4, 64) as usize;
        let batches: Vec<Batch> = (0..batch_count)
            .map(|_| generate_batch(&deployments, &mut random, rows_per_batch))
            .collect();
        let bytes_per_batch = encode_as_ipc(&schema, batches[0].columns.clone()).len();
        Self { schema, batches, rows_per_batch, bytes_per_batch }
    }

    /// The Arrow IPC stream of the batch at `index`, its rows stamped with
    /// the microsecond before `now_micros` each, later rows later.
    fn encode_stamped(&self, index: usize, now_micros: i64) -> Vec<u8> {
        let rows = self.rows_per_batch as i64;
        let mut columns = self.batches[index % self.batches.len()].columns.clone();
        let timestamps: Vec<i64> = (0..rows).map(|row| now_micros - rows + row).collect();
        let minutes: Vec<i64> = timestamps.iter().map(|at| at - at.rem_euclid(60_000_000)).collect();
        columns[TIMESTAMP_COLUMN] = Arc::new(TimestampMicrosecondArray::from(timestamps));
        columns[MINUTE_COLUMN] = Arc::new(TimestampMicrosecondArray::from(minutes));
        encode_as_ipc(&self.schema, columns)
    }
}

/// One connection's inserts into ClickHouse: stamp a batch, send it as one
/// INSERT of RowBinary through the official client, then wait until this
/// connection's share of the rate allows the next. Inserts are synchronous,
/// each one a part of its own, as the client leaves them by default. A
/// refused insert is reported and the next one sent.
async fn insert_into_clickhouse_at_rate(
    url: String,
    table: String,
    inserts_per_second: f64,
    first_batch: usize,
    pool: Arc<BatchPool>,
) {
    // A client's connections live on the runtime that opened them, so each
    // connection thread has a client of its own.
    let client = clickhouse::Client::default()
        .with_url(url)
        .with_setting("async_insert", "0")
        .with_setting("input_format_binary_read_json_as_string", "1");
    let started = Instant::now();
    for sent in 0u64.. {
        let due = Duration::from_secs_f64(sent as f64 / inserts_per_second);
        if let Some(wait) = due.checked_sub(started.elapsed()) {
            tokio::time::sleep(wait).await;
        }
        let now_micros = read_now_micros();
        let batch = &pool.batches[(first_batch + sent as usize) % pool.batches.len()];
        let first_timestamp = now_micros - batch.rows.len() as i64;
        let insert_started = Instant::now();
        let inserted = async {
            let mut insert = client.insert::<ClickHouseLog<'_>>(&table).await?;
            for (row, timestamp) in batch.rows.iter().zip(first_timestamp..) {
                insert.write(&row.stamp(timestamp)).await?;
            }
            insert.end().await
        }
        .await;
        let latency_ms = insert_started.elapsed().as_secs_f64() * 1000.0;
        let started_at = now_micros as f64 / 1e6;
        match inserted {
            Ok(()) => println!(
                "insert {started_at:.3} {latency_ms:.1} {} {}",
                pool.bytes_per_batch, pool.rows_per_batch,
            ),
            Err(error) => println!(
                "insert {started_at:.3} {latency_ms:.1} {} ERROR {}",
                pool.bytes_per_batch,
                error.to_string().replace('\n', " "),
            ),
        }
    }
}

/// One connection's inserts: stamp a batch, send it as one COPY, then wait
/// until this connection's share of the rate allows the next. A refused
/// insert is reported and the next one sent.
async fn insert_at_rate(
    connection: String,
    table: String,
    inserts_per_second: f64,
    first_batch: usize,
    pool: Arc<BatchPool>,
) {
    let (client, session) = tokio_postgres::connect(&connection, tokio_postgres::NoTls).await.unwrap();
    tokio::spawn(session);
    let statement = format!("COPY {table} FROM STDIN WITH (FORMAT arrow)");
    let started = Instant::now();
    for sent in 0u64.. {
        let due = Duration::from_secs_f64(sent as f64 / inserts_per_second);
        if let Some(wait) = due.checked_sub(started.elapsed()) {
            tokio::time::sleep(wait).await;
        }
        let now_micros = read_now_micros();
        let bytes = pool.encode_stamped(first_batch + sent as usize, now_micros);
        let byte_count = bytes.len();
        let insert_started = Instant::now();
        let inserted = async {
            let sink = client.copy_in::<_, bytes::Bytes>(&statement).await?;
            let mut sink = Box::pin(sink);
            sink.send(bytes::Bytes::from(bytes)).await?;
            sink.as_mut().finish().await
        }
        .await;
        let latency_ms = insert_started.elapsed().as_secs_f64() * 1000.0;
        let started_at = now_micros as f64 / 1e6;
        match inserted {
            Ok(_) => println!(
                "insert {started_at:.3} {latency_ms:.1} {byte_count} {}",
                pool.rows_per_batch
            ),
            // A refused insert leaves the connection usable; one that lost
            // its connection ends the run.
            Err(error) if !client.is_closed() => println!(
                "insert {started_at:.3} {latency_ms:.1} {byte_count} ERROR {}",
                error.to_string().replace('\n', " "),
            ),
            Err(error) => {
                eprintln!("an insert lost its connection: {error}");
                return;
            }
        }
    }
}

/// `unix_seconds` as the UTC date and time a SQL timestamp literal spells.
fn format_utc(unix_seconds: i64) -> String {
    let days = unix_seconds.div_euclid(86_400);
    let second_of_day = unix_seconds.rem_euclid(86_400);
    // The civil date of a day count, by Howard Hinnant's algorithm.
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 { shifted_month + 3 } else { shifted_month - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}",
        second_of_day / 3_600,
        second_of_day % 3_600 / 60,
        second_of_day % 60,
    )
}

/// What one row of the benchmark's query holds, as ClickHouse answers it.
#[derive(clickhouse::Row, serde::Deserialize)]
#[allow(dead_code)]
struct ClickHouseQueryRow {
    cluster: String,
    level: String,
    tenant: Option<String>,
    logs: u64,
}

/// Run the query again and again against ClickHouse, as
/// [`query_repeatedly`] does against pivot.
async fn query_clickhouse_repeatedly(url: String, query: String, range_seconds: i64, pause: Duration) {
    let client = clickhouse::Client::default().with_url(url);
    loop {
        let now_micros = read_now_micros();
        let since = match range_seconds {
            0 => 0,
            range_seconds => now_micros / 1_000_000 - range_seconds,
        };
        let sql = query.replace("{since}", &format!("toDateTime64('{}', 6, 'UTC')", format_utc(since)));
        let started = Instant::now();
        let outcome = client.query_raw(&sql).fetch_all::<ClickHouseQueryRow>().await;
        let latency_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started_at = now_micros as f64 / 1e6;
        match outcome {
            Ok(rows) => println!("query {started_at:.3} {latency_ms:.1} {}", rows.len()),
            Err(error) => println!(
                "query {started_at:.3} {latency_ms:.1} ERROR {}",
                error.to_string().replace('\n', " "),
            ),
        }
        tokio::time::sleep(pause).await;
    }
}

/// Run the query again and again on one connection. Each run reads the rows
/// of the last `range_seconds`, every row when that is zero: `{since}` in
/// the query text stands for the timestamp the range starts at.
async fn query_repeatedly(connection: String, query: String, range_seconds: i64, pause: Duration) {
    let (client, session) = tokio_postgres::connect(&connection, tokio_postgres::NoTls).await.unwrap();
    tokio::spawn(session);
    loop {
        let now_micros = read_now_micros();
        let since = match range_seconds {
            0 => 0,
            range_seconds => now_micros / 1_000_000 - range_seconds,
        };
        let sql = query.replace("{since}", &format!("TIMESTAMP '{}'", format_utc(since)));
        let started = Instant::now();
        let outcome = client.simple_query(&sql).await;
        let latency_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started_at = now_micros as f64 / 1e6;
        match outcome {
            Ok(messages) => {
                let rows = messages
                    .iter()
                    .filter(|message| matches!(message, SimpleQueryMessage::Row(_)))
                    .count();
                println!("query {started_at:.3} {latency_ms:.1} {rows}");
            }
            Err(error) => println!("query {started_at:.3} {latency_ms:.1} ERROR {error}"),
        }
        tokio::time::sleep(pause).await;
    }
}

/// Run `task` to its end on a thread of its own. The loader's tasks never
/// end on their own, so one that does has lost its connection, and takes the
/// whole run down with it.
fn spawn_on_own_thread<F>(task: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(task);
        std::process::exit(1);
    });
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let options: HashMap<&str, &str> = arguments
        .chunks(2)
        .map(|pair| (pair[0].trim_start_matches("--"), pair[1].as_str()))
        .collect();
    let read = |name: &str| *options.get(name).unwrap_or_else(|| panic!("--{name} is required"));
    let is_clickhouse = match read("engine") {
        "pivot" => false,
        "clickhouse" => true,
        engine => panic!("--engine is pivot or clickhouse, not {engine}"),
    };
    let connection = read("connection").to_string();
    let table = read("table").to_string();
    let inserts_per_second: f64 = read("inserts-per-second").parse().unwrap();
    let insert_bytes: u64 = read("insert-bytes").parse().unwrap();
    let seconds: u64 = read("seconds").parse().unwrap();
    let connections: usize = options.get("connections").map_or(32, |count| count.parse().unwrap());

    let pool = Arc::new(BatchPool::generate(insert_bytes));
    eprintln!(
        "{} batches of {} rows, {} Arrow bytes each",
        pool.batches.len(),
        pool.rows_per_batch,
        pool.bytes_per_batch,
    );
    for index in 0..connections {
        let (connection, table, pool) = (connection.clone(), table.clone(), pool.clone());
        let rate = inserts_per_second / connections as f64;
        if is_clickhouse {
            spawn_on_own_thread(insert_into_clickhouse_at_rate(connection, table, rate, index, pool));
        } else {
            spawn_on_own_thread(insert_at_rate(connection, table, rate, index, pool));
        }
    }
    if let Some(query_file) = options.get("query-file") {
        let query = std::fs::read_to_string(query_file).unwrap();
        let range_seconds: i64 = read("query-range-seconds").parse().unwrap();
        let pause = Duration::from_millis(read("query-pause-ms").parse().unwrap());
        if is_clickhouse {
            spawn_on_own_thread(query_clickhouse_repeatedly(connection, query, range_seconds, pause));
        } else {
            spawn_on_own_thread(query_repeatedly(connection, query, range_seconds, pause));
        }
    }
    std::thread::sleep(Duration::from_secs(seconds));
    std::process::exit(0);
}
