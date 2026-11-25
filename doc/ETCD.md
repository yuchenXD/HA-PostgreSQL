# etcd-compose.yaml：三台 VM 的協調服務

對應 `compose/etcd-compose.yaml`，每台 VM 執行一個 etcd 成員。所有命令從 Repository 根目錄執行。

`compose/` 存放三份部署檔與各 VM 自己的 `compose/.env`。Patroni 與 HAProxy 的設定由對應的 Compose 檔從 `config/` 掛載。

| VM | 服務 | 實驗環境私有 IP | 範本 |
| --- | --- | --- | --- |
| VM1 | `lab_ubuntu_node_1`、PostgreSQL + Patroni | 192.168.230.150 | `env/postgres.env.example` |
| VM2 | `lab_ubuntu_node_2`、PostgreSQL + Patroni | 192.168.230.151 | `env/postgres.env.example` |
| VM3 | `lab_ubuntu_node_3`、HAProxy | 192.168.230.152 | `env/app.env.example` |

三份 Compose 使用 Linux VM 的 host network，直接使用 VM IP 通訊。Mac M2 上請使用三台可互通的 ARM64 Linux VM，並在各 VM 安裝 Docker Engine 與 Docker Compose。可從 Registry 拉取映像，或使用 `docker load -i` 載入對應的映像封存檔。若目前的帳號需要 sudo 才能存取 Docker，以下 Docker 命令要加上 `sudo`。

## 準備環境變數

VM1 與 VM2 共用 PostgreSQL 範本，在各自的 VM 執行以下命令。範本預填 VM1 的節點設定。VM2 在啟動服務前，先把 `compose/.env` 裡的七個值改成 [VM2 的設定](POSTGRES.md#vm2-專用設定)。

```bash
test -e compose/.env || install -m 600 env/postgres.env.example compose/.env
```

VM3 使用 App 範本。

```bash
test -e compose/.env || install -m 600 env/app.env.example compose/.env
```

已部署的 VM 保留現有 `compose/.env`，依範本補上 `ETCD_VOLUME_NAME`。若使用不同的私有 IP，更新各範本對應的 peer、client 與 HAProxy backend 位址。三台使用相同的 `ETCD_INITIAL_CLUSTER_TOKEN`。

## 首次建立叢集

VM1 以 `new` 建立單成員叢集。VM2 與 VM3 以 `existing` 依序加入，peer 清單各自對應加入當下的成員。以下步驟用於三台都還沒有 etcd 資料的情況。

### 1. 在 VM1 建立叢集並登記 VM2

```bash
docker compose --env-file compose/.env -f compose/etcd-compose.yaml up -d --wait
docker compose --env-file compose/.env -f compose/etcd-compose.yaml exec etcd \
  etcdctl member add lab_ubuntu_node_2 --peer-urls=http://192.168.230.151:2380 --learner
```

### 2. 在 VM2 啟動 etcd

先核對 `member add` 印出的 `ETCD_INITIAL_CLUSTER` 與 `ETCD_INITIAL_CLUSTER_STATE`。

```bash
docker compose --env-file compose/.env -f compose/etcd-compose.yaml up -d
```

### 3. 回到 VM1 提升 VM2 並登記 VM3

將 `MEMBER_ID` 設成 `member add` 回傳的 VM2 ID。若 etcd 回報 learner 尚未追上，等同步後再重試 `member promote`。

```bash
MEMBER_ID='填入 VM2 的成員 ID'
docker compose --env-file compose/.env -f compose/etcd-compose.yaml exec etcd \
  etcdctl member promote "$MEMBER_ID" &&
docker compose --env-file compose/.env -f compose/etcd-compose.yaml exec etcd \
  etcdctl member add lab_ubuntu_node_3 --peer-urls=http://192.168.230.152:2380 --learner
```

### 4. 在 VM3 啟動 etcd，再回 VM1 提升 VM3

核對 VM3 的設定後，在 VM3 執行步驟 2 的啟動命令。回 VM1 填入 VM3 的成員 ID，執行以下命令。成員加入與提升的細節見 [etcd Runtime reconfiguration](https://etcd.io/docs/v3.6/op-guide/runtime-configuration/#add-a-new-member)。

```bash
MEMBER_ID='填入 VM3 的成員 ID'
docker compose --env-file compose/.env -f compose/etcd-compose.yaml exec etcd \
  etcdctl member promote "$MEMBER_ID"
```

### 5. 在 VM1 檢查三個成員

確認三個投票成員與 client endpoint 都正常，再依 `POSTGRES.md` 與 `APP.md` 啟動資料庫與連線入口。

```bash
docker compose --env-file compose/.env -f compose/etcd-compose.yaml exec etcd etcdctl member list
docker compose --env-file compose/.env -f compose/etcd-compose.yaml exec etcd \
  etcdctl --endpoints=http://192.168.230.150:2379,http://192.168.230.151:2379,http://192.168.230.152:2379 endpoint health
```

## 網路與資料

- TCP 2379：只允許三台 VM 存取，供 Patroni 與 etcd client 使用。
- TCP 2380：只允許三台 VM 互通，供 etcd peer 使用。
- etcd 的 Compose 專案名稱為 `ha-etcd`。三台的 named volume 依序為 `ha-etcd-volume_1`、`ha-etcd-volume_2`、`ha-etcd-volume_3`。
- 這套實驗設定使用私有網路 HTTP，尚未配置 etcd TLS／驗證；正式部署需另行設計。

既有叢集重啟時沿用原本的 volume 和成員設定。替換或新增成員應以目前的叢集成員清單為準，透過 etcd membership 流程處理，並為新成員使用空的資料 volume。

## 停止

```bash
docker compose --env-file compose/.env -f compose/etcd-compose.yaml stop etcd
```

一次維護一個成員，保留另外兩個在線。不要執行 `down -v`，除非確定要刪除該 VM 的叢集資料。
