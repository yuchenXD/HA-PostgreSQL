# PostgreSQL 備份與還原操作手冊

本文件只保留目前專案的操作流程。參數與設計說明請參閱 [本專案的 PostgreSQL PITR 備份流程](../tutorial/BACKUP_DOC.md)。

所有 Shell 指令都在專案根目錄執行。

| 操作 | 位置 |
| --- | --- |
| 正式 Primary SQL | DBeaver → `127.0.0.1:5001`，database `postgres` |
| 隔離還原 SQL | DBeaver → `127.0.0.1:55432`，使用來源資料庫帳密 |
| 邏輯備份還原 SQL | DBeaver → `127.0.0.1:55433`，database `postgres` |
| Docker、Patroni、備份檔案 | Shell |

> 不要執行 `docker compose down -v`。來源故障時，不要刪除 PostgreSQL data volumes。

## 一、備份前檢查

```bash
docker compose config --quiet
docker compose up -d
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list
docker compose exec pg-node-1 df -h /wal-archive /pitr-base
```

在正式 Primary 執行：

```sql
SHOW archive_mode;

SELECT archived_count,
       failed_count,
       last_archived_wal,
       last_archived_time,
       last_failed_wal,
       last_failed_time
FROM pg_stat_archiver;

SELECT spcname,
       pg_tablespace_location(oid) AS location
FROM pg_tablespace
WHERE length(pg_tablespace_location(oid)) > 0;
```

繼續條件：一個 Leader、Replica 為 `streaming`、`archive_mode=on`、歸檔無連續失敗、空間充足、自訂 tablespace 查詢結果為空。

## 二、建立 base backup

### 1. 執行備份

```bash
export BACKUP_ID="base_$(date +%Y%m%d_%H%M%S)"

docker compose exec -e BACKUP_ID="$BACKUP_ID" pg-node-1 sh -ceu '
  umask 077
  START_TIME="$(date --iso-8601=seconds)"
  mkdir "/pitr-base/$BACKUP_ID"

  export PGPASSWORD="$PATRONI_REPLICATION_PASSWORD"
  pg_basebackup \
    --host=haproxy \
    --port=5000 \
    --username="$PATRONI_REPLICATION_USERNAME" \
    --pgdata="/pitr-base/$BACKUP_ID" \
    --format=plain \
    --wal-method=stream \
    --checkpoint=fast \
    --label="$BACKUP_ID" \
    --progress

  pg_verifybackup --exit-on-error "/pitr-base/$BACKUP_ID"
  END_TIME="$(date --iso-8601=seconds)"

  printf "backup_id=%s\nstart_time=%s\nend_time=%s\nverified=true\n" \
    "$BACKUP_ID" "$START_TIME" "$END_TIME" \
    > "/pitr-base/${BACKUP_ID}.meta"
'
```

任一命令失敗時，停止流程並改用新的 `BACKUP_ID` 重做。

### 2. 驗證結果

```bash
docker compose exec -e BACKUP_ID="$BACKUP_ID" pg-node-1 sh -ceu '
  test -s "/pitr-base/$BACKUP_ID/backup_manifest"
  test -s "/pitr-base/${BACKUP_ID}.meta"
  grep -q "verified=true" "/pitr-base/${BACKUP_ID}.meta"
  cat "/pitr-base/${BACKUP_ID}.meta"
  du -sh "/pitr-base/$BACKUP_ID"
'
```

完成後，將 `backups/pitr/base` 與 `backups/pitr/wal` 複製到不同故障域。

### 3. 建立 restore point（選用）

在正式 Primary 執行，名稱必須唯一：

```sql
SELECT pg_create_restore_point('before_release_20261022_153000');
```

## 三、日常巡檢

在正式 Primary 執行：

```sql
SELECT archived_count,
       failed_count,
       last_archived_wal,
       last_archived_time,
       last_failed_wal,
       last_failed_time
FROM pg_stat_archiver;
```

在 Shell 執行：

```bash
docker compose exec pg-node-1 df -h /wal-archive /pitr-base
```

立即處理下列任一狀況：

- `failed_count` 持續增加。
- `last_archived_time` 長時間不更新。
- `/wal-archive` 或 `/pitr-base` 空間不足。

不要只依日期刪除 WAL。刪除前必須確認保留的 base backup 到目前時間之間仍有完整 WAL。

## 四、獨立單機 PostgreSQL PITR 還原演練

還原實例使用官方 `postgres:18` image 直接啟動 PostgreSQL，不使用 Docker Compose、Patroni、etcd 或 HAProxy，也不掛載 HA 節點的 data volume。它與 HA 執行環境之間唯一的關係，是讀取 HA 事先產生的 base backup 與 WAL archive。

### 1. 設定還原目標

目標時間必須包含時區、晚於 base backup 的 `end_time`，且位於 WAL 保存範圍內。

```bash
export BACKUP_ID='base_20261030_113021'
export RECOVERY_TARGET_TIME='2026-10-30 16:18:00+08'
export RESTORE_ID="$(date +%Y%m%d_%H%M%S)"
export RESTORE_VOLUME="standalone-pitr-data-${RESTORE_ID}"
export RESTORE_CONTAINER="standalone-pitr-${RESTORE_ID}"
export PITR_BACKUP_ROOT='./backups/pitr'
export PITR_BACKUP_ABS="$(cd "$PITR_BACKUP_ROOT" && pwd)"

test -s "$PITR_BACKUP_ABS/base/$BACKUP_ID/backup_manifest"
grep -q 'verified=true' "$PITR_BACKUP_ABS/base/${BACKUP_ID}.meta"
cat "$PITR_BACKUP_ABS/base/${BACKUP_ID}.meta"
```

來源 Primary 可用時，在正式 Primary 執行：

```sql
SELECT pg_switch_wal();

SELECT archived_count,
       failed_count,
       last_archived_wal,
       last_archived_time,
       last_failed_wal,
       last_failed_time
FROM pg_stat_archiver;
```

確認 `last_archived_time` 已更新後繼續。

> 來源已故障時，先保存各節點的 `pg_wal`，不要刪除原 data volumes。

### 2. 建立獨立還原資料

```bash
docker volume create "$RESTORE_VOLUME"

docker run \
  --user root \
  --mount type=bind,src="$PITR_BACKUP_ABS/base/$BACKUP_ID",dst=/backup,readonly \
  --mount type=volume,src="$RESTORE_VOLUME",dst=/restore \
  --entrypoint sh \
  postgres:18 \
  -ceu "
    cp -a /backup/. /restore/
    printf '%s\\n' \\
      \"restore_command = 'cp /wal-archive/%f %p'\" \\
      \"recovery_target_time = '${RECOVERY_TARGET_TIME}'\" \\
      \"recovery_target_timeline = 'latest'\" \\
      \"recovery_target_action = 'pause'\" \\
      \"primary_conninfo = ''\" \\
      \"primary_slot_name = ''\" \\
      >> /restore/postgresql.auto.conf
    rm -f /restore/standby.signal
    touch /restore/recovery.signal
    chown -R postgres:postgres /restore
    chmod 0700 /restore
  "
```

`RESTORE_VOLUME` 是每次演練新建的空 volume，不是 HA Primary 或 Replica 使用的 volume。上述容器只負責將已驗證的 base backup 複製為新 `PGDATA`，不需要連線到 HA 網路。

若使用 restore point，將 `recovery_target_time` 改為：

```conf
recovery_target_name = 'before_release_20261022_153000'
```

### 3. 啟動獨立單機 PostgreSQL

```bash
docker run --detach \
  --name "$RESTORE_CONTAINER" \
  --user postgres \
  --publish 127.0.0.1:55432:5432 \
  --mount type=volume,src="$RESTORE_VOLUME",dst=/var/lib/postgresql/18/docker \
  --mount type=bind,src="$PITR_BACKUP_ABS/wal",dst=/wal-archive,readonly \
  --entrypoint /usr/lib/postgresql/18/bin/postgres \
  postgres:18 \
  -D /var/lib/postgresql/18/docker \
  -c archive_mode=off \
  -c synchronous_standby_names='' \
  -c cluster_name=standalone-pitr \
  -c listen_addresses='*'

docker logs --tail=100 "$RESTORE_CONTAINER"
```

此 `docker run` 沒有加入 HA Compose network，也沒有啟動 Patroni。`synchronous_standby_names=''` 會清除備份中原本針對 HA Replica 的同步等待要求，避免還原完成後的單機寫入被卡住。

### 4. 驗證還原點

使用來源資料庫原本的 database、role 與 password 連到 `127.0.0.1:55432`。實體備份會還原來源 system catalogs，因此不會使用新的 `POSTGRES_USER` 或 `POSTGRES_PASSWORD` 初始化帳密。

在隔離還原實例執行：

```sql
SELECT pg_is_in_recovery(),
       pg_get_wal_replay_pause_state(),
       pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp();
```

切換到 application database，執行實際資料驗證：

```sql
SELECT count(*)
FROM public.important_table;
```

通過條件：

- `pg_is_in_recovery()` 為 `true`。
- `pg_get_wal_replay_pause_state()` 為 `paused`。
- Replay 時間與資料內容符合目標。
- PostgreSQL log 沒有缺少必要 WAL。

### 5. 接受或重做

目標正確時，在隔離還原實例執行：

```sql
SELECT pg_wal_replay_resume();
SELECT pg_is_in_recovery();
```

完成條件：`pg_is_in_recovery()` 為 `false`。

此實例仍不是 Patroni 成員，不可直接切入正式流量。

目標不正確時：

1. 不要執行 `pg_wal_replay_resume()`。
2. 停止本次容器。
3. 使用新的 `RESTORE_ID` 與 recovery target，從步驟 1 重做。

### 6. 清理演練資源

確認不需保留本次演練後執行：

```bash
docker rm -f "$RESTORE_CONTAINER"
docker volume rm "$RESTORE_VOLUME"
```

## 五、邏輯備份與直接匯入演練

本節使用 `pg_dump` 建立單一 database 的邏輯備份，再使用 `pg_restore` 直接匯入新 PostgreSQL。這是邏輯備份還原，不是 PITR。

### 1. 建立邏輯備份

```bash
export SOURCE_DATABASE='postgres'
export DUMP_ID="${SOURCE_DATABASE}_$(date +%Y%m%d_%H%M%S)"
export LOGICAL_BACKUP_DIR='./backups/logical'

mkdir -p "$LOGICAL_BACKUP_DIR"
```

```bash
docker compose exec -T \
  -e SOURCE_DATABASE="$SOURCE_DATABASE" \
  -e DUMP_ID="$DUMP_ID" \
  pg-node-1 sh -ceu '
    export PGPASSWORD="$PATRONI_SUPERUSER_PASSWORD"
    pg_dump \
      --host=haproxy \
      --port=5000 \
      --username="$PATRONI_SUPERUSER_USERNAME" \
      --dbname="$SOURCE_DATABASE" \
      --format=custom \
      --file="/tmp/${DUMP_ID}.dump"
  '
```

```bash
docker cp \
  "postgres-ha-node-1:/tmp/${DUMP_ID}.dump" \
  "$LOGICAL_BACKUP_DIR/${DUMP_ID}.dump"

chmod 0600 "$LOGICAL_BACKUP_DIR/${DUMP_ID}.dump"
```

```bash
docker compose exec -T \
  -e DUMP_ID="$DUMP_ID" \
  pg-node-1 rm -f "/tmp/${DUMP_ID}.dump"
```

備份檔會位於：

```text
./backups/logical/${DUMP_ID}.dump
```

### 2. 啟動不使用 Docker volume 的新 PostgreSQL

```bash
export RESTORE_CONTAINER='postgres-logical-restore-demo'
export RESTORE_USER='restore_admin'
export RESTORE_PASSWORD='restore-demo-only'
export RESTORE_DATABASE='postgres'
```

```bash
docker run --detach \
  --name "$RESTORE_CONTAINER" \
  --publish 127.0.0.1:55433:5432 \
  --tmpfs /var/lib/postgresql:rw \
  --env POSTGRES_USER="$RESTORE_USER" \
  --env POSTGRES_PASSWORD="$RESTORE_PASSWORD" \
  --env POSTGRES_DB="$RESTORE_DATABASE" \
  postgres:18
```

```bash
docker logs --follow "$RESTORE_CONTAINER"
```

顯示 `database system is ready to accept connections` 後，按 `Ctrl+C` 離開 log。

```bash
docker exec "$RESTORE_CONTAINER" \
  pg_isready \
    --username="$RESTORE_USER" \
    --dbname="$RESTORE_DATABASE"
```

### 3. 將邏輯備份匯入新 PostgreSQL

```bash
docker cp \
  "$LOGICAL_BACKUP_DIR/${DUMP_ID}.dump" \
  "$RESTORE_CONTAINER:/tmp/${DUMP_ID}.dump"
```

```bash
docker exec \
  --env PGPASSWORD="$RESTORE_PASSWORD" \
  "$RESTORE_CONTAINER" \
  pg_restore \
    --username="$RESTORE_USER" \
    --dbname="$RESTORE_DATABASE" \
    --exit-on-error \
    --no-owner \
    --no-privileges \
    "/tmp/${DUMP_ID}.dump"
```

### 4. 驗證還原結果

```bash
docker exec \
  --env PGPASSWORD="$RESTORE_PASSWORD" \
  "$RESTORE_CONTAINER" \
  psql \
    --username="$RESTORE_USER" \
    --dbname="$RESTORE_DATABASE" \
    --no-psqlrc \
    --command='SELECT current_database(), current_user, version();'
```

使用 DBeaver 驗證應用資料：

```text
Host: 127.0.0.1
Port: 55433
Database: postgres
User: restore_admin
Password: restore-demo-only
```

### 5. 清理邏輯還原演練

```bash
docker rm --force "$RESTORE_CONTAINER"
```

`backups/logical/${DUMP_ID}.dump` 不會被刪除。

## 六、完成檢查

- [ ] 一個 Leader，Replica 為 `streaming`。
- [ ] WAL archive 持續更新且沒有連續失敗。
- [ ] `pg_verifybackup` 成功。
- [ ] `${BACKUP_ID}.meta` 包含 `verified=true`。
- [ ] Base backup 與 WAL 已複製到不同故障域。
- [ ] 已完成隔離 PITR 還原及資料驗證。
- [ ] 需要邏輯備份時，已實際執行 `pg_dump` 與 `pg_restore` 演練。
