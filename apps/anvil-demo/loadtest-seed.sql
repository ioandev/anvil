-- Generated data for the demo's load-test copy (scripts/loadtest anvil-demo seed N): N approved guestbook entries,
-- nothing from production. {N} is replaced by the script. Runs as root in the copy's own MariaDB, never on atlas.
SET SESSION sql_log_bin = 0;
DELETE FROM entry_queue; DELETE FROM entries; DELETE FROM daily_stats;
INSERT INTO entries (name, message, created_at, approved_at)
  SELECT CONCAT('Visitor ', seq), CONCAT('Generated entry number ', seq, ' for the load test.'),
         NOW(3) - INTERVAL seq SECOND, NOW(3) - INTERVAL seq SECOND
  FROM seq_1_to_{N};
SELECT CONCAT('entries ', COUNT(*), ', size ',
  (SELECT ROUND(SUM(data_length + index_length) / 1048576) FROM information_schema.tables WHERE table_schema = DATABASE()), ' MB')
  FROM entries;
