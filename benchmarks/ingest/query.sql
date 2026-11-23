-- How many logs each cluster, level and tenant wrote since {since}, which the
-- loader replaces with the start of the time range on every run.
SELECT cluster, level, (attributes->'tenant')::VARCHAR AS tenant, count(*) AS logs
FROM logs
WHERE "timestamp" >= {since}
GROUP BY ALL
ORDER BY logs DESC, cluster, level, tenant
LIMIT 100;
