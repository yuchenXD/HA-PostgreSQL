# postgres-compose.yaml：每台資料庫 VM 一個節點

對應 `compose/postgres-compose.yaml` 與 `config/patroni.yaml`，部署於 VM1（192.168.230.150）與 VM2（192.168.230.151）。前置步驟與 VM 網路配置見 `ETCD.md`。

## 環境變數與 Image

1. VM1 和 VM2 各自依 `env/postgres.env.example` 建立 `compose/.env`。範本預填 VM1 的節點設定，VM2 請套用下方的七個值。兩台使用相同的 `ETCD_HOSTS`。
2. 首次部署請替換三個密碼佔位文字。兩台須使用相同的 superuser、replication 與 API 帳密；修改 replication 帳號時須同步修改 Patroni 的 `pg_hba`。
3. 已部署的 VM 沿用現有帳密，依範本補上 `POSTGRES_VOLUME_NAME` 與 `POSTGRES_IMAGE`，並核對 `ETCD_HOSTS` 的三個位址。

### VM2 專用設定

在 VM2 的 `compose/.env` 替換以下七行。

```dotenv
VM_IP=192.168.230.151
ETCD_NAME=lab_ubuntu_node_2
ETCD_INITIAL_CLUSTER=lab_ubuntu_node_1=http://192.168.230.150:2380,lab_ubuntu_node_2=http://192.168.230.151:2380
ETCD_INITIAL_CLUSTER_STATE=existing
ETCD_VOLUME_NAME=ha-etcd-volume_2
PATRONI_NAME=pg-node-2
POSTGRES_VOLUME_NAME=ha-postgres-volume_2
```

### 掛載檔權限與映像

Patroni 以非 root 的 `postgres` 使用者執行。`config/patroni.yaml` 不含帳密，請允許容器讀取；本機 Compose 的檔案型 `configs` 使用 bind mount，不能依賴 `uid`／`gid`／`mode` 改變原始檔案權限。帳密檔仍維持 `600`：

```bash
chmod 644 config/patroni.yaml
chmod 600 compose/.env
```

實驗範本使用 `POSTGRES_IMAGE=postgres-patroni:offline`。將映像封存檔放到兩台資料庫 VM 後，各自載入：

```bash
docker load -i image/postgres-patroni.tar
```

若使用 Docker Hub 的 `yuchen1226/postgres-patroni:18.6-patroni4.1.5`，請把 `POSTGRES_IMAGE` 改成該標籤。也可以在兩台 ARM64 Linux VM 各自從 `image/Dockerfile` 建置同名映像：

```bash
docker build -t yuchen1226/postgres-patroni:18.6-patroni4.1.5 image
```

如果建置環境需要 HTTPS 代理 CA，額外傳入 `--secret id=proxy_ca,src=/path/to/ca-bundle.pem`。映像發布至 Docker Hub 後，也可在兩台 VM 拉取同一個有 ARM64 支援的 tag／digest：

```bash
docker pull yuchen1226/postgres-patroni:18.6-patroni4.1.5
```

發布者先以 Docker Hub 帳號登入，再使用支援目標架構的 Buildx builder 建置並推送。M2 的 Linux VM 需要 `linux/arm64`；不要僅發布 `linux/amd64`：

```bash
docker login -u yuchen1226
docker buildx build --platform linux/amd64,linux/arm64 \
  -t yuchen1226/postgres-patroni:18.6-patroni4.1.5 \
  --push image
```

## 啟動

先確認三個 etcd 成員健康，再到 VM1、VM2 各自執行：

```bash
docker compose --env-file compose/.env -f compose/postgres-compose.yaml up -d --wait
docker compose --env-file compose/.env -f compose/postgres-compose.yaml exec postgres patronictl -c /etc/patroni/patroni.yml list
```

兩台可以並行啟動，Patroni 會透過 etcd 選出 Primary。每台的 PostgreSQL 與 Patroni 都使用自己的 VM IP。

VM1 使用 `ha-postgres-volume_1`，VM2 使用 `ha-postgres-volume_2`。更新既有部署時，請先核對 `POSTGRES_VOLUME_NAME` 與原本的 volume 名稱。

## 連線與複寫策略

- TCP 5432：綁定各自的 VM IP；允許 VM3、另一個資料庫 VM 及必要管理來源。
- TCP 8008：綁定各自的 VM IP；允許 HAProxy、另一個 Patroni 節點及必要管理來源。
- 節點角色會改變；Application 連線至 VM3 的 `192.168.230.152:5000`，由 HAProxy 找出 Primary。
- 目前保留嚴格同步複寫與一個同步副本。只剩一個資料庫節點時，交易提交會等待；這套設定不承諾資料庫 VM 故障後仍持續可寫。

`pg_hba` 允許經 SCRAM 驗證的遠端連線；必須用 VM 防火牆限制來源。host network 的服務直接由 VM 網路承接，不會經過 Docker published ports。

## 維護

```bash
docker compose --env-file compose/.env -f compose/postgres-compose.yaml stop postgres
```

只停止資料庫可保留同機 etcd。一般停止或重建容器不刪除 named volume；`down -v` 會刪資料。既有叢集的密碼需另行輪替；`bootstrap.dcs` 只於初始化生效，之後透過 Patroni 修改動態設定。
