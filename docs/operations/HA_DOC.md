# PostgreSQL HA 操作手冊

本文件針對目前這套 Docker Compose 實驗環境，整理日常啟停、狀態查閱、功能測試、故障切換及常見修復方式。

資料備份、還原、驗證與 PITR 操作請參閱 [PostgreSQL Backup 操作手冊](./BACKUP_DOC.md)。

架構原理請參閱 [PostgreSQL HA 教學](../tutorial/HA_DOC.md)。

## 目前環境

| 元件 | Compose service | Container | 主機入口 |
| --- | --- | --- | --- |
| PostgreSQL / Patroni node 1 | `pg-node-1` | `postgres-ha-node-1` | PostgreSQL `5432`、Patroni `8008` |
| PostgreSQL / Patroni node 2 | `pg-node-2` | `postgres-ha-node-2` | PostgreSQL `5433`、Patroni `8009` |
| etcd | `etcd` | `postgres-ha-etcd-1` | 僅 Docker 內部網路 |
| HAProxy | `haproxy` | `postgres-ha-haproxy` | PostgreSQL `5001`、狀態頁 `7001` |

節點名稱不代表固定角色。`pg-node-1` 和 `pg-node-2` 都可能成為 Primary，也都可能成為 Replica。

目前使用可降級的同步複寫：Replica 正常時，Primary 必須等待一個同步 Replica 將 WAL flush 到持久儲存後，交易才會回覆成功；若同步 Replica 不可用，Patroni 會暫時解除同步要求，讓剩餘的 Primary 繼續寫入。降級期間的新資料只有一份，若唯一存活節點再次故障，可能遺失尚未複寫的交易。

### 設定檔位置

```text
postgreSQL/
├── docker-compose.yaml
├── .env
├── patroni/
│   ├── Dockerfile
│   └── patroni.yml
├── haproxy/
│   └── haproxy.cfg
└── docs/
```

- `docker-compose.yaml`：容器、網路、volume、port 與 config 掛載。
- `patroni/patroni.yml`：Patroni、PostgreSQL、同步複寫與 `pg_hba` 設定。
- `haproxy/haproxy.cfg`：Primary 健康檢查與流量路由。
- `.env`：帳號及密碼等環境變數。

外部 `patroni.yml` 不會進行 Compose `${...}` 變數替換，因此 `pg_hba` 內固定使用 replication username `replicator`。若修改 `.env` 的 `REPLICATION_USER`，也必須同步修改 `patroni/patroni.yml` 中兩條 replication 規則。

## 安全提醒

以下指令會刪除所有 PostgreSQL 與 etcd volumes，除非確定資料可丟棄，否則不要執行：

```bash
docker compose down -v
```

一般停止環境只使用：

```bash
docker compose down
```

## 建置與啟停

### 第一次建置或 Patroni Dockerfile 變更後

```bash
docker compose pull etcd haproxy
docker compose build --no-cache pg-node-1 pg-node-2
```

### 驗證設定檔

先驗證 Compose：

```bash
docker compose config --quiet
```

Patroni 驗證器也會確認 DCS 可達，因此先暫時啟動 etcd，再驗證獨立 YAML：

```bash
docker compose up -d etcd

docker compose run --rm --no-deps pg-node-1 \
  --validate-config /etc/patroni/patroni.yml \
  --ignore-listen-port

docker compose stop etcd
```

### 將同步設定套用至既有叢集

`patroni/patroni.yml` 中的 `bootstrap.dcs` 只會在第一次建立 DCS 時套用。若 PostgreSQL 與 etcd volumes 已存在，修改同步相關的 bootstrap 值後，還必須更新 etcd 中的 Patroni 動態設定：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml \
  edit-config pg-ha \
  --set synchronous_mode=true \
  --set synchronous_mode_strict=false \
  --set synchronous_node_count=1 \
  --set postgresql.parameters.synchronous_commit=on \
  --force
```

此設定可線上套用，不需要刪除 volumes。套用後確認：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml \
  show-config pg-ha
```

應看到：

```yaml
synchronous_mode: true
synchronous_mode_strict: false
synchronous_node_count: 1
postgresql:
  parameters:
    synchronous_commit: 'on'
```

驗證 HAProxy 設定：

```bash
docker compose run --rm --no-deps haproxy \
  haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
```

### 啟動

```bash
docker compose up -d
```

### 查看容器狀態

```bash
docker compose ps
```

### 停止但保留資料

```bash
docker compose down
```

### 重啟單一服務

```bash
docker compose restart pg-node-1
docker compose restart pg-node-2
docker compose restart haproxy
docker compose restart etcd
```

## 日常查閱

### 查看 Patroni 拓撲

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list
```

正常情況應具備：

- 一個 `Leader`，狀態通常為 `running`。
- 一個 `Sync Standby` 或 Replica，狀態通常為 `streaming`。
- Replica lag 接近 `0`。

`streaming` 代表 Replica 正在接收 WAL，不代表故障。兩個節點都正常時，還需確認 PostgreSQL 的 `sync_state` 為 `sync`。

### 查看同步複寫狀態

先找出目前 Leader，使用資料庫用戶端直接連線至該節點（node 1 使用 `5432`、node 2 使用 `5433`），然後執行：

```sql
SHOW synchronous_commit;
SHOW synchronous_standby_names;

SELECT application_name,
       state,
       sync_state,
       write_lsn,
       flush_lsn,
       replay_lsn
FROM pg_stat_replication;
```

正常結果：

- `synchronous_commit` 為 `on`。
- `synchronous_standby_names` 不是空字串，且由 Patroni 管理。
- Replica 的 `state` 為 `streaming`。
- Replica 的 `sync_state` 為 `sync`。

### 查看 Patroni REST API

```bash
curl -s http://127.0.0.1:8008/patroni
curl -s http://127.0.0.1:8009/patroni
```

檢查目前誰是 Primary：

```bash
for port in 8008 8009; do
  printf "Port %s /primary: " "$port"
  curl -s -o /dev/null -w '%{http_code}\n' \
    "http://127.0.0.1:${port}/primary"
done
```

正常情況只有一個節點回傳 `200`，另一個回傳 `503`。

檢查 Replica：

```bash
for port in 8008 8009; do
  printf "Port %s /replica: " "$port"
  curl -s -o /dev/null -w '%{http_code}\n' \
    "http://127.0.0.1:${port}/replica"
done
```

### 從 SQL 確認角色

使用資料庫用戶端分別直接連線至 node 1（`5432`）和 node 2（`5433`），在兩個連線中執行相同查詢：

```sql
SELECT pg_is_in_recovery();
```

結果解讀：

- `false`：Primary，可寫入。
- `true`：Replica，處於 recovery，只能讀取。

### 查看 HAProxy

狀態頁：<http://127.0.0.1:7001/stats>

`patroni_primary` backend 中只有當前 Primary 應顯示 `UP`。Replica 顯示 `DOWN` 是預期行為，表示它沒有通過 `/primary` 角色檢查，不代表 PostgreSQL 故障。

### 查看日誌

全部服務：

```bash
docker compose logs --tail=200
```

持續查看 PostgreSQL、Patroni 與 HAProxy：

```bash
docker compose logs --tail=100 -f pg-node-1 pg-node-2 haproxy
```

只找常見錯誤關鍵字：

```bash
docker compose logs --no-color pg-node-1 pg-node-2 | \
  grep -Ei 'error|warn|leader|lock|promot|demot|timeline|rewind|system id'
```

## 測試流程

建議依序執行。每個測試完成後，先確認叢集回到一個 Leader、一個 streaming Replica，再進入下一項。

### T01：基礎健康狀態

```bash
docker compose ps
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list
```

通過標準：

- etcd 與兩個 PostgreSQL 節點為 healthy。
- HAProxy 為 running。
- 叢集只有一個 Leader。
- 另一個節點為 streaming Sync Standby。
- Leader 的 `pg_stat_replication.sync_state` 為 `sync`。

### T02：HAProxy Primary 路由

使用資料庫用戶端經 HAProxy `5001` 連線，然後執行：

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

通過標準：`pg_is_in_recovery()` 必須為 `false`。

### T03：寫入與 Streaming Replication

透過 HAProxy 建立測試資料：

```sql
CREATE TABLE IF NOT EXISTS ha_test (
    id bigint PRIMARY KEY,
    created_at timestamptz DEFAULT now()
);

INSERT INTO ha_test (id)
VALUES (1)
ON CONFLICT DO NOTHING;

SELECT *
FROM ha_test
ORDER BY id;
```

接著使用資料庫用戶端分別直接連線至 node 1（`5432`）和 node 2（`5433`），在兩個連線中執行：

```sql
SELECT pg_is_in_recovery(), *
FROM ha_test
ORDER BY id;
```

通過標準：

- 兩邊都能讀到相同資料。
- 只有一邊的 `pg_is_in_recovery()` 為 `false`。
- Leader 上的 `pg_stat_replication.sync_state` 為 `sync`。
- `synchronous_commit` 為 `on`。

### T04：Primary 故障與自動 Failover

先用 `patronictl list` 確認目前 Leader。假設目前是 `pg-node-2`：

```bash
docker compose stop pg-node-2
```

重複查看：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list
```

通過標準：

- 原 Replica 在數十秒後成為 Leader。
- 新 Leader 的 `/primary` 回傳 `200`。
- HAProxy 狀態頁切換至新 Leader。
- Patroni 在沒有 Replica 時暫時解除同步要求。
- 經 `5001` 建立的新資料庫連線可再次寫入；這可能需要再等待一次 HA loop。

既有資料庫連線會中斷；HAProxy 只會把新連線導向新 Primary，不會保存失敗中的 transaction。資料庫用戶端或應用程式必須重新連線，且只能在確認前一筆交易的最終狀態後安全重試。

### T05：Failover 後寫入

確認 `SHOW synchronous_standby_names;` 已變成空字串後，重新使用資料庫用戶端經 HAProxy `5001` 建立連線，然後執行：

```sql
INSERT INTO ha_test (id)
VALUES (2)
ON CONFLICT DO NOTHING;

SELECT *
FROM ha_test
ORDER BY id;
```

通過標準：即使舊 Primary 尚未恢復，仍可寫入並看到 `id = 1` 與 `id = 2`。此時 `id = 2` 暫時只存在新 Primary；在 Replica 重新加入前，應將叢集視為降級狀態。

### T06：舊 Primary 恢復並成為 Replica

啟動先前停止的節點：

```bash
docker compose start pg-node-2
```

查看拓撲：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list
```

通過標準：

- 現任 Leader 不變。
- 舊 Primary 重新加入成為 streaming Sync Standby。
- Replica lag 最終回到接近 `0`。
- 新舊測試資料都存在。
- `synchronous_standby_names` 再次由 Patroni 設定，後續 commit 恢復等待同步 Replica。

### T07：Replica 故障

確認哪個節點是 Replica 後停止它：

```bash
docker compose stop pg-node-2
```

通過標準：

- Primary 角色不改變。
- HAProxy `5001` 仍可建立新連線及讀取。
- 寫入可能在 Patroni 偵測 Replica 離線期間短暫等待。
- Patroni 解除同步要求後，Primary 可在沒有 Replica 時繼續寫入。
- 降級期間的新交易只有一份，第二次節點故障可能造成資料遺失。

經 HAProxy 建立新連線，重複查詢：

```sql
SHOW synchronous_standby_names;
```

等結果變成空字串後驗證降級寫入：

```sql
INSERT INTO ha_test (id)
VALUES (3)
ON CONFLICT DO NOTHING;

SELECT *
FROM ha_test
ORDER BY id;
```

通過標準：不需要等待 Replica 修復即可看到 `id = 3`。測試後重新啟動剛才停止的 Replica，等待它回到 streaming/sync，再進入下一項：

```bash
docker compose start pg-node-2
```

若實際 Replica 是 `pg-node-1`，請改用對應的 service 名稱。

### T08：計畫性 Switchover

假設 node 1 是 Leader、node 2 是 Replica：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml \
  switchover pg-ha \
  --leader pg-node-1 \
  --candidate pg-node-2 \
  --force
```

如果角色相反，請交換 `--leader` 和 `--candidate`。

通過標準：角色平滑互換，HAProxy 隨後將新連線導向新 Leader。

### T09：資料持久化

```bash
docker compose down
docker compose up -d
```

等待叢集健康後再次查詢 `ha_test`。

通過標準：資料仍存在，且叢集重新形成一個 Leader、一個 Replica。

### T10：HAProxy 單點測試

```bash
docker compose stop haproxy
```

預期：PostgreSQL 叢集仍運作，但 `5001` 暫時無法連線。

HAProxy 故障期間，可使用 PostgreSQL JDBC Driver 的多主機連線功能，直接嘗試兩個節點並只接受目前 Primary。在 DBeaver 建立一個備援連線、選擇「Connect by URL」，使用：

```text
jdbc:postgresql://127.0.0.1:5432,127.0.0.1:5433/postgres?targetServerType=primary&connectTimeout=3
```

Username 與 Password 仍分別填入 DBeaver 欄位。連線後驗證：

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

通過標準：即使 HAProxy 已停止，多主機連線仍可建立，且 `pg_is_in_recovery()` 為 `false`。這是 JDBC Driver 的備援能力；既有連線中斷後仍必須重新連線，Driver 不會保存失敗中的 transaction。

恢復：

```bash
docker compose start haproxy
```

這項測試用來證明目前只有一個 HAProxy，因此 HAProxy 本身仍是單點。

## 常見問題與修復

### 問題：兩個節點的 `pg_is_in_recovery()` 都是 `true`

這代表兩個 PostgreSQL 都是 Replica，或者兩次查詢實際連到同一個節點。

先使用資料庫用戶端分別直接連線至 node 1（`5432`）和 node 2（`5433`），不要經過 HAProxy，然後在兩個連線中執行相同查詢，以排除兩次查詢實際連到同一節點：

```sql
SELECT pg_is_in_recovery();
```

接著確認 Patroni 與 etcd：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list

docker compose exec etcd \
  /usr/local/bin/etcdctl \
  --endpoints=http://127.0.0.1:2379 endpoint health
```

若沒有 Leader，查看 Patroni 日誌中的 leader lock、timeline、system ID 或 DCS 錯誤。不要在原因未確認時同時手動 promote 兩個節點。

### 問題：容器是 running，但 health 顯示 unhealthy

```bash
docker compose logs --tail=200 pg-node-1
docker compose exec pg-node-1 sh -lc \
  '/opt/patroni/bin/python -c "import urllib.request; urllib.request.urlopen('\''http://127.0.0.1:8008/health'\'', timeout=2)"'
```

常見原因包括 PostgreSQL 尚未啟動、Patroni 無法連 etcd、資料目錄問題或啟動時間超過 healthcheck 的等待時間。

### 問題：HAProxy `5001` 無法連線

先確認是否有 Primary：

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8008/primary
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8009/primary
```

再檢查設定和日誌：

```bash
docker compose run --rm --no-deps haproxy \
  haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg

docker compose logs --tail=200 haproxy
```

若兩個 `/primary` 都回傳 `503`，問題在 Patroni 選主，不是 HAProxy。

若 Patroni 已有正常 Primary、但 HAProxy 暫時無法修復，可在 DBeaver 使用 PostgreSQL JDBC Driver 的多主機備援 URL，直接選出可寫節點：

```text
jdbc:postgresql://127.0.0.1:5432,127.0.0.1:5433/postgres?targetServerType=primary&connectTimeout=3
```

`targetServerType=primary` 會排除 Replica，避免將寫入送往唯讀節點。此連線繞過 HAProxy，只適合作為目前單機實驗環境的補救入口；正式環境仍應使用多個 HAProxy 搭配 VIP 或外部 Load Balancer，並將 PostgreSQL 節點部署到不同主機。

### 問題：Replica 長時間不是 streaming 或 lag 持續增加

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml list

docker compose logs --tail=300 pg-node-1 pg-node-2
```

確認目前 Replica 後，使用資料庫用戶端直接連線至該 Replica，查看 WAL receiver：

```sql
SELECT status,
       sender_host,
       sender_port,
       latest_end_lsn
FROM pg_stat_wal_receiver;
```

如果 Replica 已無法透過 WAL 追上，可由 Primary 重新複製。以下操作會刪除指定 Replica 的本機資料，執行前必須再次確認目標不是 Leader：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml \
  reinit pg-ha pg-node-2 --force
```

### 問題：Replica 停止後，INSERT/UPDATE/COMMIT 一直等待

Replica 剛離線時，寫入可能短暫等待 Patroni 下一次 HA loop。若持續等待，先確認動態設定確實為 `synchronous_mode_strict: false`：

```bash
docker compose exec pg-node-1 \
  patronictl -c /etc/patroni/patroni.yml \
  show-config pg-ha
```

再使用資料庫用戶端連線至目前 Leader，查詢同步要求及 replication 狀態：

```sql
SHOW synchronous_standby_names;

SELECT application_name,
       state,
       sync_state
FROM pg_stat_replication;
```

沒有 Replica 時，`synchronous_standby_names` 最終應變成空字串。若仍為 `*`，查看 Patroni 與 etcd 日誌，確認 HA loop 能更新 DCS 與 PostgreSQL。不要用 session 層的 `synchronous_commit=off` 掩蓋 Patroni 設定問題。

### 問題：DBeaver 在 Failover 後出現 `08006`

Failover 會中斷連到舊 Primary 的既有 TCP session。請在 DBeaver 對連線執行 Disconnect/Connect 或 Invalidate/Reconnect，重新開啟 SQL Editor，再透過 HAProxy 連線。HAProxy 只能把新連線送往新 Primary，不能搬移既有 transaction。

目前 HAProxy 的 client/server timeout 為 30 分鐘；應用程式仍應具備失敗重連及只對可安全重試交易進行重試的機制。

### 問題：舊 Primary 無法重新加入

先查看該節點是否在執行 `pg_rewind`，或是否出現 timeline/system ID 錯誤：

```bash
docker compose logs --tail=300 pg-node-1 pg-node-2 | \
  grep -Ei 'rewind|timeline|system id|fatal|error'
```

若無法自動修復，可在確認它不是 Leader 後，使用上一節的 `patronictl reinit` 重建該 Replica。

### 問題：etcd 不健康

```bash
docker compose logs --tail=200 etcd
docker compose exec etcd \
  /usr/local/bin/etcdctl \
  --endpoints=http://127.0.0.1:2379 endpoint status --write-out=table
```

目前只有一個 etcd；它停止時沒有其他 etcd 成員可形成 quorum。先恢復 etcd，再觀察 Patroni 是否重新取得 leader lock。

### 問題：修改 Dockerfile 後仍使用舊 Patroni

```bash
docker compose build --no-cache pg-node-1 pg-node-2
docker compose up -d --force-recreate pg-node-1 pg-node-2
```

確認版本：

```bash
docker compose exec pg-node-1 patroni --version
docker compose exec pg-node-2 patroni --version
```

### 完全重建實驗環境

只有在所有資料都可以刪除時使用：

```bash
docker compose down --remove-orphans -v
docker compose build --no-cache pg-node-1 pg-node-2
docker compose up -d
```

此操作會永久刪除：

- PostgreSQL node 1 資料。
- PostgreSQL node 2 資料。
- etcd 中的 Patroni 叢集狀態。
