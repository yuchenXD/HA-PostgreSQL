# PostgreSQL HA 與 PITR 建置結果報告

- 執行日期：2026-10-22（Asia/Taipei）
- 專案：PostgreSQL 18 + Patroni 4.1.5 + etcd + HAProxy
- 備份方案：Host bind mount（方案一）

## 1. 設定調整

- `docker-compose.yaml` 已將兩個 PostgreSQL 節點共同掛載：
  - `${PITR_BACKUP_ROOT}/wal` → `/wal-archive`
  - `${PITR_BACKUP_ROOT}/base` → `/pitr-base`
- `.env` 已設定 `PITR_BACKUP_ROOT=./backups/pitr`。
- PostgreSQL data 仍使用 `pg-primary-data`、`pg-standby-data` named volumes；本次沒有刪除任何既有 volume。
- Patroni 已啟用：
  - `archive_mode=on`
  - `archive_command=test ! -f /wal-archive/%f && cp %p /wal-archive/%f`
  - `archive_timeout=60s`
- `docker compose config --quiet` 驗證通過。

## 2. PostgreSQL HA 結果

| Member | Role | State | Timeline | Replication lag | Pending restart |
|---|---|---|---:|---:|---|
| `pg-node-2` | Leader | running | 1 | - | 無 |
| `pg-node-1` | Sync Standby | streaming | 1 | 0 | 無 |

`etcd`、`pg-node-1`、`pg-node-2` 均為 healthy；HAProxy 已啟動並於主機 `127.0.0.1:5001` 提供 Primary 連線。

## 3. 測試資料與備份前檢查

- 測試 SQL：`tests/pitr_backup_test.sql`
- 建立資料表：`public.pitr_backup_test`
- 測試 marker：`pitr_base_backup_test_20261022`
- 寫入時間：`2026-10-22 14:53:29.938 +0800`
- DBeaver 查詢確認測試資料存在。
- WAL 設定檢查：
  - `archive_mode`：`on`
  - `archive_timeout`：`1min`
  - `archive_command`：符合 `/wal-archive` bind mount
  - `failed_count`：`0`
  - 自訂 tablespace 數量：`0`
- `pg_switch_wal()` 已執行，主機 WAL 目錄可看到已歸檔檔案。

## 4. Base backup 結果

| 項目 | 結果 |
|---|---|
| Backup ID | `base_20261022_145439` |
| 開始時間 | `2026-10-22 14:54:46 +0800` |
| 完成時間 | `2026-10-22 14:54:47 +0800` |
| 主機路徑 | `backups/pitr/base/base_20261022_145439` |
| Base backup 大小 | 約 39 MB |
| WAL archive 大小 | 約 96 MB |
| WAL 目錄檔案數 | 8 |
| `pg_verifybackup` | 成功（`backup successfully verified`） |
| Metadata | `backups/pitr/base/base_20261022_145439.meta`，`verified=true` |

備份透過 HAProxy 的 Primary endpoint 建立，使用 `pg_basebackup --wal-method=stream --checkpoint=fast`，完成後已執行 `pg_verifybackup --exit-on-error`。

## 5. 最終狀態與注意事項

- 備份完成後，Leader 與 Sync Standby 仍正常，複寫延遲為 0。
- WAL archive 會持續運作；在沒有自然 WAL segment 切換時，`archive_timeout=60s` 會促使歸檔進展。
- Base backup 目前是手動執行，尚未設定 cron 或其他自動排程。
- Host bind mount 可避免備份只存在 Docker named volume，但不能防止主機磁碟故障；正式使用前應將 `backups/pitr/base` 與 `backups/pitr/wal` 複製到另一個故障域。
- 本次完成的是備份建立與完整性驗證，尚未執行獨立 PITR 還原演練。
