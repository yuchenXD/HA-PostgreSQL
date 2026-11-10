# postgres-compose.yaml：每台資料庫 VM 一個節點

對應 `compose/postgres-compose.yaml` 與 `config/patroni.yaml`，部署於 VM2、VM3。前置步驟與 VM 網路配置見 `ETCD.md`。

## 環境變數與 Image

1. 在各 VM 建立自己的 `env/vm2.env` 或 `env/vm3.env`，設定 `VM_IP`、唯一的 `PATRONI_NAME`，以及三個 etcd client 位址。
2. 在 VM2 複製 `env/.env.example` 為 `env/.env`，替換三個密碼佔位文字，設定權限 `chmod 600 env/.env`。
3. 透過安全管道將同一份帳密提供給 VM3；兩個資料庫節點必須使用相同的 superuser、replication 與 API 帳密。保留預設帳號名稱；修改 replication 帳號時須同步修改 Patroni 的 `pg_hba`。

```bash
cp env/.env.example env/.env
chmod 600 env/.env
```

真實 `.env` 與 `vm*.env` 不進 Git；範本可以提交。原本單機用的 `env/.env` 如已存在，可以沿用帳密，不要直接覆寫。

`POSTGRES_IMAGE` 預設為我們自建的 Image 名稱。最簡單的 ARM64 實驗方式是在兩台 ARM64 Linux VM 各自從 `image/Dockerfile` 建置：

```bash
docker build -t local/ha-postgresql:18.6-patroni4.1.5 image
```

如果建置環境需要 HTTPS 代理 CA，額外傳入 `--secret id=proxy_ca,src=/path/to/ca-bundle.pem`。也可事先發布到 Docker Hub，兩台使用同一個有 ARM64 支援的 Image tag／digest，再修改 `POSTGRES_IMAGE`。本次不建立或推送 Docker Hub Image。

## 啟動

先確認三個 etcd 成員健康。VM2 執行：

```bash
docker compose --env-file env/.env --env-file env/vm2.env -f compose/etcd-compose.yaml -f compose/postgres-compose.yaml up -d --wait
docker compose --env-file env/.env --env-file env/vm2.env -f compose/etcd-compose.yaml -f compose/postgres-compose.yaml exec postgres patronictl -c /etc/patroni/patroni.yml list
```

VM3 將 `vm2.env` 換成 `vm3.env`。兩台並行啟動即可，Patroni 會透過 etcd 選出 Primary。每台的 PostgreSQL 與 Patroni 都宣告自己的 VM IP，無需跨 VM Docker service discovery。

各 VM 的 PostgreSQL data 使用自己獨立的 `postgres-data` named volume。此為重新初始化的新叢集，不會自動搬移舊單機 named volume 的資料。

## 連線與複寫策略

- TCP 5432：綁定各自的 VM IP；允許 VM1、另一個資料庫 VM 及必要管理來源。
- TCP 8008：綁定各自的 VM IP；允許 HAProxy、另一個 Patroni 節點及必要管理來源。
- 節點角色會改變；Application 使用 `APP_VM_IP:5000`，由 HAProxy 找出 Primary。
- 目前保留嚴格同步複寫與一個同步副本。只剩一個資料庫節點時，交易提交會等待；這套設定不承諾資料庫 VM 故障後仍持續可寫。

`pg_hba` 允許經 SCRAM 驗證的遠端連線；必須用 VM 防火牆限制來源。host network 的服務直接由 VM 網路承接，不會經過 Docker published ports。

## 維護

```bash
docker compose --env-file env/.env --env-file env/vm2.env -f compose/etcd-compose.yaml -f compose/postgres-compose.yaml stop postgres
```

只停止資料庫可保留同機 etcd。一般停止或重建容器不刪除 named volume；`down -v` 會刪資料。既有叢集的密碼需另行輪替；`bootstrap.dcs` 只於初始化生效，之後透過 Patroni 修改動態設定。

目前只驗證 Compose 設定結構；尚未進行 ARM64 建置或跨 VM 複寫／故障切換測試。
