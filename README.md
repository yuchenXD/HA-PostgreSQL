# HA-PostgreSQL

以 Docker Compose 建立的 PostgreSQL 18 高可用性實驗環境，整合 Patroni、etcd、同步串流複寫、HAProxy，以及 PITR（Point-in-Time Recovery）備份與還原流程。

## 架構

- 2 個 PostgreSQL 18 + Patroni 節點
- etcd 作為 Patroni DCS
- HAProxy 自動將新連線導向目前的 Primary
- 同步串流複寫與自動故障切換
- WAL archive、base backup 與隔離還原演練

## 快速開始

1. 複製環境變數範本並更換所有密碼：

   ```bash
   cp .env.example .env
   ```

2. 建立備份目錄並啟動服務：

   ```bash
   mkdir -p backups/pitr/base backups/pitr/wal
   docker compose up -d --build
   ```

3. 查看服務狀態：

   ```bash
   docker compose ps
   docker compose exec pg-node-1 patronictl -c /etc/patroni/patroni.yml list
   ```

應用程式可透過 `127.0.0.1:5001` 連到目前 Primary；節點診斷連接埠為 `5432` 與 `5433`，HAProxy 狀態頁位於 `http://127.0.0.1:7001/stats`。

## 文件

- [HA 架構教學](docs/tutorial/HA_DOC.md)
- [HA 操作手冊](docs/operations/HA_DOC.md)
- [PITR 備份教學](docs/tutorial/BACKUP_DOC.md)
- [PITR 備份與還原操作手冊](docs/operations/BACKUP_DOC.md)

## 安全提醒

`.env`、`backups/` 與執行期資料不會納入版本控制。請勿將正式密碼、私鑰或包含真實資料的 PostgreSQL 備份提交至公開儲存庫。

## License

[MIT](LICENSE)
