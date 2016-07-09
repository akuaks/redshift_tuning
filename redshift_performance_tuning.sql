--------------------
-- Incorrect column encoding
--------------------

SELECT database, schema || '.' || "table" AS "table", encoded, size
FROM svv_table_info 
WHERE encoded='N'
ORDER BY 2;

SELECT trim(n.nspname || '.' || c.relname) AS "table",trim(a.attname) AS "column",format_type(a.atttypid, a.atttypmod) AS "type", 
format_encoding(a.attencodingtype::integer) AS "encoding", a.attsortkeyord AS "sortkey"
FROM pg_namespace n, pg_class c, pg_attribute a 
WHERE n.oid = c.relnamespace AND c.oid = a.attrelid AND a.attnum > 0 AND NOT a.attisdropped and n.nspname NOT IN ('information_schema','pg_catalog','pg_toast') AND format_encoding(a.attencodingtype::integer) = 'none' AND c.relkind='r' AND a.attsortkeyord != 1 ORDER BY n.nspname, c.relname, a.attnum;

--  Note that the first column in a compound sort key should not be encoded


--------------------
-- Skewed table data
--------------------

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/table_inspector.sql

DROP TABLE IF EXISTS temp_staging_tables_1;
DROP TABLE IF EXISTS temp_staging_tables_2;
DROP TABLE IF EXISTS temp_tables_report;

CREATE TEMP TABLE temp_staging_tables_1
                 (schemaname TEXT,
                  tablename TEXT,
                  tableid BIGINT,
                  size_in_megabytes BIGINT);

INSERT INTO temp_staging_tables_1
SELECT n.nspname, c.relname, c.oid, 
      (SELECT COUNT(*) FROM STV_BLOCKLIST b WHERE b.tbl = c.oid)
FROM pg_namespace n, pg_class c
WHERE n.oid = c.relnamespace 
  AND nspname NOT IN ('pg_catalog', 'pg_toast', 'information_schema','pg_internal')
  AND c.relname <> 'temp_staging_tables_1';

CREATE TEMP TABLE temp_staging_tables_2
                 (tableid BIGINT,
                  min_blocks_per_slice BIGINT,
                  max_blocks_per_slice BIGINT,
                  slice_count BIGINT);

INSERT INTO temp_staging_tables_2
SELECT tableid, MIN(c), MAX(c), COUNT(DISTINCT slice)
FROM (SELECT t.tableid, slice, COUNT(*) AS c
      FROM temp_staging_tables_1 t, STV_BLOCKLIST b
      WHERE t.tableid = b.tbl
      GROUP BY t.tableid, slice)
GROUP BY tableid;

CREATE TEMP TABLE temp_tables_report
                 (schemaname TEXT,
                 tablename TEXT,
                 tableid BIGINT,
                 size_in_mb BIGINT,
                 has_dist_key INT,
                 has_sort_key INT,
                 has_col_encoding INT,
                 pct_skew_across_slices FLOAT,
                 pct_slices_populated FLOAT);

INSERT INTO temp_tables_report
SELECT t1.*,
       CASE WHEN EXISTS (SELECT *
                         FROM pg_attribute a
                         WHERE t1.tableid = a.attrelid
                           AND a.attnum > 0
                           AND NOT a.attisdropped
                           AND a.attisdistkey = 't')
            THEN 1 ELSE 0 END,
       CASE WHEN EXISTS (SELECT *
                         FROM pg_attribute a
                         WHERE t1.tableid = a.attrelid
                           AND a.attnum > 0
                           AND NOT a.attisdropped
                           AND a.attsortkeyord > 0)
           THEN 1 ELSE 0 END,
      CASE WHEN EXISTS (SELECT *
                        FROM pg_attribute a
                        WHERE t1.tableid = a.attrelid
                          AND a.attnum > 0
                          AND NOT a.attisdropped
                          AND a.attencodingtype <> 0)
            THEN 1 ELSE 0 END,
      100 * CAST(t2.max_blocks_per_slice - t2.min_blocks_per_slice AS FLOAT)
            / CASE WHEN (t2.min_blocks_per_slice = 0) 
                   THEN 1 ELSE t2.min_blocks_per_slice END,
      CAST(100 * t2.slice_count AS FLOAT) / (SELECT COUNT(*) FROM STV_SLICES)
FROM temp_staging_tables_1 t1, temp_staging_tables_2 t2
WHERE t1.tableid = t2.tableid;

SELECT * FROM temp_tables_report
ORDER BY schemaname, tablename;


--------------------
-- Queries not benefiting from sort keys
--------------------

-- Note: Queries evaluated against a sort key column must not apply a SQL function to the sort key

SELECT database, table_id, schema || '.' || "table" AS "table", size, nvl(s.num_qs,0) num_qs
FROM svv_table_info t
LEFT JOIN (SELECT tbl, COUNT(distinct query) num_qs
FROM stl_scan s
WHERE s.userid > 1
  AND s.perm_table_name NOT IN ('Internal Worktable','S3')
GROUP BY tbl) s ON s.tbl = t.table_id
WHERE t.sortkey1 IS NULL
ORDER BY 5 desc;

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/filter_used.sql
-- Return instances of table filter for all or a given table in the past 7 days
select trim(s.perm_Table_name) as table , substring(trim(info),1,580) as filter, sum(datediff(seconds,starttime,case when starttime > endtime then starttime else endtime end)) as secs, count(distinct i.query) as num, max(i.query) as query
from stl_explain p
join stl_plan_info i on ( i.userid=p.userid and i.query=p.query and i.nodeid=p.nodeid  )
join stl_scan s on (s.userid=i.userid and s.query=i.query and s.segment=i.segment and s.step=i.step)
where s.starttime > dateadd(day, -7, current_Date)
and s.perm_table_name not like 'Internal Worktable%'
and p.info like 'Filter:%'  and p.nodeid > 0
and s.perm_table_name like '%' -- choose table(s) to look for
group by 1,2 order by 1, 3 desc , 4 desc;


--------------------
-- Tables without statistics or which need vacuum
--------------------

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/missing_table_stats.sql
SELECT substring(trim(plannode),1,100) AS plannode
       ,COUNT(*)
FROM stl_explain
WHERE plannode LIKE '%missing statistics%'
AND plannode NOT LIKE '%redshift_auto_health_check_%'
GROUP BY plannode
ORDER BY 2 DESC;

-- Determine tables that have stale statistics
SELECT database, schema || '.' || "table" AS "table", stats_off 
FROM svv_table_info 
WHERE stats_off > 5 
ORDER BY 2;


--------------------
-- Tables with very large VARCHAR columns
--------------------

-- Tables that should have their maximum column widths reviewed
SELECT database, schema || '.' || "table" AS "table", max_varchar 
FROM svv_table_info 
WHERE max_varchar > 150 
ORDER BY 2;

-- Determine true maximum width of column
SELECT max(len(rtrim(column_name))) 
FROM table_name;

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/top_queries.sql
-- Top 50 time consuming statements aggregated by its text
select trim(database) as DB, count(query) as n_qry, max(substring (qrytext,1,80)) as qrytext, min(run_seconds) as "min" , max(run_seconds) as "max", avg(run_seconds) as "avg", sum(run_seconds) as total,  max(query) as max_query_id, 
max(starttime)::date as last_run, aborted, event
from (
select userid, label, stl_query.query, trim(database) as database, trim(querytxt) as qrytext, md5(trim(querytxt)) as qry_md5, starttime, endtime, datediff(seconds, starttime,endtime)::numeric(12,2) as run_seconds, 
       aborted, decode(alrt.event,'Very selective query filter','Filter','Scanned a large number of deleted rows','Deleted','Nested Loop Join in the query plan','Nested Loop','Distributed a large number of rows across the network','Distributed','Broadcasted a large number of rows across the network','Broadcast','Missing query planner statistics','Stats',alrt.event) as event
from stl_query 
left outer join ( select query, trim(split_part(event,':',1)) as event from STL_ALERT_EVENT_LOG where event_time >=  dateadd(day, -7, current_Date)  group by query, trim(split_part(event,':',1)) ) as alrt on alrt.query = stl_query.query
where userid <> 1 
-- and (querytxt like 'SELECT%' or querytxt like 'select%' ) 
-- and database = ''
and starttime >=  dateadd(day, -7, current_Date)
 ) 
group by database, label, qry_md5, aborted, event
order by total desc limit 50;

-- Pay special attention to SELECT * queries which include the JSON fragment column
-- If end users query these large columns but don’t use actually execute JSON functions against them, consider moving them into another table that only contains the primary key column of the original table and the JSON column


--------------------
-- Queries waiting on queue slots
--------------------

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/commit_stats.sql
-- Return commit queue statistics from past 2 days, showing largest queue length and queue time first
select startqueue,node, datediff(ms,startqueue,startwork) as queue_time, datediff(ms, startwork, endtime) as commit_time, queuelen 
from stl_commit_stats 
where startqueue >=  dateadd(day, -2, current_Date)
order by queuelen desc , queue_time desc;

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/wlm_apex_hourly.sql
-- Returns the per-hour high water-mark for WLM query queues
WITH
        -- Replace STL_SCAN in generate_dt_series with another table which has > 604800 rows if STL_SCAN does not
        generate_dt_series AS (select sysdate - (n * interval '1 second') as dt from (select row_number() over () as n from stl_scan limit 604800)),
        apex AS (SELECT iq.dt, iq.service_class, iq.num_query_tasks, count(iq.slot_count) as service_class_queries, sum(iq.slot_count) as service_class_slots
                FROM
                (select gds.dt, wq.service_class, wscc.num_query_tasks, wq.slot_count
                FROM stl_wlm_query wq
                JOIN stv_wlm_service_class_config wscc ON (wscc.service_class = wq.service_class AND wscc.service_class > 4)
                JOIN generate_dt_series gds ON (wq.service_class_start_time <= gds.dt AND wq.service_class_end_time > gds.dt)
                WHERE wq.userid > 1 AND wq.service_class > 4) iq
        GROUP BY iq.dt, iq.service_class, iq.num_query_tasks),
        maxes as (SELECT apex.service_class, trunc(apex.dt) as d, date_part(h,apex.dt) as dt_h, max(service_class_slots) max_service_class_slots
                        from apex group by apex.service_class, apex.dt, date_part(h,apex.dt))
SELECT apex.service_class, apex.num_query_tasks as max_wlm_concurrency, maxes.d as day, maxes.dt_h || ':00 - ' || maxes.dt_h || ':59' as hour, MAX(apex.service_class_slots) as max_service_class_slots
FROM apex
JOIN maxes ON (apex.service_class = maxes.service_class AND apex.service_class_slots = maxes.max_service_class_slots)
GROUP BY  apex.service_class, apex.num_query_tasks, maxes.d, maxes.dt_h
ORDER BY apex.service_class, maxes.d, maxes.dt_h;

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/wlm_apex.sql
-- Returns the high-water mark for WLM query queues and time queuing was last encountered
WITH 
	generate_dt_series AS (select sysdate - (n * interval '1 second') as dt from (select row_number() over () as n from svl_query_report limit 604800)),
	-- generate_dt_series AS (select sysdate - (n * interval '1 second') as dt from (select row_number() over () as n from [table_with_604800_rows] limit 604800)),
	apex AS (SELECT iq.dt, iq.service_class, iq.num_query_tasks, count(iq.slot_count) as service_class_queries, sum(iq.slot_count) as service_class_slots
		FROM  
		(select gds.dt, wq.service_class, wscc.num_query_tasks, wq.slot_count
		FROM stl_wlm_query wq
		JOIN stv_wlm_service_class_config wscc ON (wscc.service_class = wq.service_class AND wscc.service_class > 4)
		JOIN generate_dt_series gds ON (wq.service_class_start_time <= gds.dt AND wq.service_class_end_time > gds.dt)
		WHERE wq.userid > 1 AND wq.service_class > 4) iq
	GROUP BY iq.dt, iq.service_class, iq.num_query_tasks),
	maxes as (SELECT apex.service_class, max(service_class_slots) max_service_class_slots 
			from apex group by apex.service_class),
	queued as (	select service_class, max(queue_end_time) max_queue_end_time from stl_wlm_query where total_queue_time > 0 GROUP BY service_class)
select apex.service_class, apex.num_query_tasks as max_wlm_concurrency, apex.service_class_slots as max_service_class_slots, max(apex.dt) max_slots_ts, queued.max_queue_end_time last_queued_time
FROM apex
JOIN maxes ON (apex.service_class = maxes.service_class AND apex.service_class_slots = maxes.max_service_class_slots)
LEFT JOIN queued ON queued.service_class = apex.service_class
GROUP BY  apex.service_class, apex.num_query_tasks, apex.service_class_slots, queued.max_queue_end_time
ORDER BY apex.service_class;


--------------------
-- Queries that are disk-based
--------------------

SELECT
q.query, trim(q.cat_text)
FROM (SELECT query, replace( listagg(text,' ') WITHIN GROUP (ORDER BY sequence), '\\n', ' ') AS cat_text FROM stl_querytext WHERE userid>1 GROUP BY query) q
JOIN
(SELECT distinct query FROM svl_query_summary WHERE is_diskbased='t' AND (LABEL LIKE 'hash%' OR LABEL LIKE 'sort%' OR LABEL LIKE 'aggr%') AND userid > 1) qs ON qs.query = q.query;


--------------------
-- Commit queue waits
--------------------

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/queuing_queries.sql
SELECT w.query
       ,substring(q.querytxt,1,100) AS querytxt
       ,w.queue_start_time
       ,w.service_class AS class
       ,w.slot_count AS slots
       ,w.total_queue_time / 1000000 AS queue_seconds
       ,w.total_exec_time / 1000000 exec_seconds
       ,(w.total_queue_time + w.total_Exec_time) / 1000000 AS total_seconds
FROM stl_wlm_query w
  LEFT JOIN stl_query q
         ON q.query = w.query
        AND q.userid = w.userid
WHERE w.queue_start_Time >= dateadd(day,-7,CURRENT_DATE)
AND   w.total_queue_Time > 0
-- and q.starttime >= dateadd(day, -7, current_Date)    
-- and ( querytxt like 'select%' or querytxt like 'SELECT%' ) 
ORDER BY w.total_queue_time DESC
         ,w.queue_start_time DESC limit 35


--------------------
-- Using explain plan alerts
--------------------

-- https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminScripts/perf_alert.sql
-- Return alerts from past 7 days
select trim(s.perm_table_name) as table , (sum(abs(datediff(seconds, coalesce(b.starttime,d.starttime,s.starttime), case when coalesce(b.endtime,d.endtime,s.endtime) > coalesce(b.starttime,d.starttime,s.starttime) THEN coalesce(b.endtime,d.endtime,s.endtime) ELSE coalesce(b.starttime,d.starttime,s.starttime) END )))/60)::numeric(24,0) as minutes,
       sum(coalesce(b.rows,d.rows,s.rows)) as rows, trim(split_part(l.event,':',1)) as event,  substring(trim(l.solution),1,60) as solution , max(l.query) as sample_query, count(distinct l.query)
from stl_alert_event_log as l
left join stl_scan as s on s.query = l.query and s.slice = l.slice and s.segment = l.segment
left join stl_dist as d on d.query = l.query and d.slice = l.slice and d.segment = l.segment
left join stl_bcast as b on b.query = l.query and b.slice = l.slice and b.segment = l.segment
where l.userid >1
and  l.event_time >=  dateadd(day, -7, current_Date)
-- and s.perm_table_name not like 'volt_tt%'
group by 1,4,5 order by 2 desc,6 desc;
