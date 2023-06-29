#!/bin/bash

if [[ $UID -ge 10000 ]]; then
    GID=$(id -g)
    sed -e "s/^postgres:x:[^:]*:[^:]*:/postgres:x:$UID:$GID:/" /etc/passwd > /tmp/passwd
    cat /tmp/passwd > /etc/passwd
    rm /tmp/passwd
fi

mkdir /scripts

cat > /scripts/post_init.sh <<__EOF__
#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PGVER=$(psql -d "$2" -XtAc "SELECT pg_catalog.current_setting('server_version_num')::int/10000")
if [ "$PGVER" -ge 12 ]; then RESET_ARGS="oid, oid, bigint"; fi

python3 database_init.py | PGOPTIONS="-c synchronous_commit=local" psql

(echo "DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_authid WHERE rolname = 'admin';
    IF FOUND THEN
        ALTER ROLE admin WITH CREATEDB NOLOGIN NOCREATEROLE NOSUPERUSER NOREPLICATION INHERIT;
    ELSE
        CREATE ROLE admin CREATEDB;
    END IF;
END;\$\$;

DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_authid WHERE rolname = '$1';
    IF FOUND THEN
        ALTER ROLE $1 WITH NOCREATEDB NOLOGIN NOCREATEROLE NOSUPERUSER NOREPLICATION INHERIT;
    ELSE
        CREATE ROLE $1;
    END IF;
END;\$\$;

CREATE EXTENSION IF NOT EXISTS file_fdw SCHEMA public;
DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_foreign_server WHERE srvname = 'pglog';
    IF NOT FOUND THEN
        CREATE SERVER pglog FOREIGN DATA WRAPPER file_fdw;
    END IF;
END;\$\$;"

while IFS= read -r db_name; do
    echo "\c ${db_name}"
    sed "s/:HUMAN_ROLE/$1/" create_user_functions.sql
    echo "CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_kcache SCHEMA public;
GRANT EXECUTE ON FUNCTION public.pg_stat_statements_reset($RESET_ARGS) TO admin;"
    if [ "$PGVER" -lt 10 ]; then
        echo "GRANT EXECUTE ON FUNCTION pg_catalog.pg_switch_xlog() TO admin;"
    else
        echo "GRANT EXECUTE ON FUNCTION pg_catalog.pg_switch_wal() TO admin;"
    fi
    cat metric_helpers.sql
done < <(psql -d "$2" -tAc 'select pg_catalog.quote_ident(datname) from pg_catalog.pg_database where datallowconn')
) | PGOPTIONS="-c synchronous_commit=local" psql -Xd "$2"
__EOF__

chmod +x /scripts/post_init.sh

cat > /home/postgres/patroni.yml <<__EOF__
bootstrap:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: false
      pg_hba:
      - host all all 0.0.0.0/0 md5
      - host replication ${PATRONI_REPLICATION_USERNAME} ${PATRONI_KUBERNETES_POD_IP}/16 md5
      parameters:
        wal_level: hot_standby
        hot_standby: 'on'
        max_connections: '443'
        max_replication_slots: '999'
        max_wal_senders: '999'
        max_worker_processes: '8'
        wal_level: logical
        archive_mode: "on"
        archive_timeout: 1800s
        archive_command: mkdir -p ../wal_archive && test ! -f ../wal_archive/%f && cp %p ../wal_archive/%f && sleep 1
        autovacuum: 'on'
        autovacuum_analyze_scale_factor: '0.01'
        autovacuum_max_workers: '5'
        autovacuum_vacuum_scale_factor: '0.05'
        default_statistics_target: '500'
        effective_io_concurrency: '100'
        fsync: 'on'
        hot_standby_feedback: 'on'
        idle_in_transaction_session_timeout: 15min
        idle_session_timeout: 24h
        log_autovacuum_min_duration: 5s
        log_checkpoints: 'on'
        log_connections: 'on'
        log_directory: ../pg_log
        log_disconnections: 'off'
        log_file_mode: '0644'
        log_line_prefix: '%m [%p] %q%a %u@%d %r '
        log_lock_waits: 'on'
        log_min_duration_sample: 500ms
        log_rotation_age: 1d
        log_rotation_size: 512MB
        log_statement: ddl
        log_statement_sample_rate: '0.05'
        logging_collector: 'on'
        max_parallel_workers: '8'
        max_wal_size: 8GB
        password_encryption: scram-sha-256
        pg_stat_statements.max: '10000'
        pg_stat_statements.track: all
        pg_stat_statements.track_utility: 'off'
        random_page_cost: '1.1'
        seq_page_cost: '1.0'
        statement_timeout: 5s
        tcp_keepalives_idle: '900'
        tcp_keepalives_interval: '100'
        track_activities: 'on'
        track_activity_query_size: '4096'
        track_functions: all
        track_io_timing: 'on'
        wal_buffers: 64MB
        wal_compression: 'on'
  initdb:  # Note: It needs to be a list (some options need values, others are switches)
  - encoding: UTF8
  - data-checksums
  - encoding: UTF8
  - locale: en_US.UTF-8
  - wal-segsize: '64'
  - auth-host: md5
  - auth-local: trust
  post_init: /scripts/post_init.sh "dre"
restapi:
  connect_address: '${PATRONI_KUBERNETES_POD_IP}:8008'
postgresql:
  connect_address: '${PATRONI_KUBERNETES_POD_IP}:5432'
  authentication:
    superuser:
      password: '${PATRONI_SUPERUSER_PASSWORD}'
    replication:
      password: '${PATRONI_REPLICATION_PASSWORD}'
__EOF__

unset PATRONI_SUPERUSER_PASSWORD PATRONI_REPLICATION_PASSWORD

exec /usr/bin/python3 /usr/local/bin/patroni /home/postgres/patroni.yml
