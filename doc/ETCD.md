# etcd-compose.yaml：三台 VM 的協調服務

對應 `compose/etcd-compose.yaml`，每台 VM 執行一個 etcd 成員。所有命令從 Repository 根目錄執行。

`compose/` 僅存放三份 `*-compose.yaml` 部署檔；Patroni 與 HAProxy 的服務設定分別放在 `config/patroni.yaml` 與 `config/haproxy.cfg`，由對應的 Compose 檔掛載。

| VM | 服務 | 範例私有 IP | 節點設定檔 |
| --- | --- | --- | --- |
| VM1 | etcd-1、HAProxy、未來的 Application | 192.168.64.11 | env/vm1.env |
| VM2 | etcd-2、PostgreSQL + Patroni | 192.168.64.12 | env/vm2.env |
| VM3 | etcd-3、PostgreSQL + Patroni | 192.168.64.13 | env/vm3.env |

三份 Compose 使用 Linux VM 的 host network，直接使用 VM IP，不依賴跨主機 Docker DNS。Mac M2 上請建立三台 ARM64 Linux VM，在各 VM 裡安裝 Docker Engine 與 Compose v2；不要直接在 macOS 執行這些部署命令。VM 必須彼此可達，且能連出至 Image registry。

## 準備與啟動

每台 VM 複製 Repository，複製自己對應的環境範本。例如 VM1：

```bash
cp env/vm1.env.example env/vm1.env
```

VM2、VM3 分別使用 `vm2`、`vm3`。依實際 VM 網路修改範本 IP；三台的 `APP_VM_IP`、`PG_NODE_1_IP`、`PG_NODE_2_IP`、`ETCD_INITIAL_CLUSTER`、`ETCD_HOSTS`、`ETCD_INITIAL_CLUSTER_TOKEN` 必須一致。`VM_IP` 與 `ETCD_NAME` 各自不同。

`ETCD_INITIAL_CLUSTER` 是完整的三成員 peer 清單；`ETCD_HOSTS` 是 Patroni 使用的三個 client endpoint，不含 `http://`。使用固定 IP 或 DHCP reservation，避免重啟後位址改變。

先在三台 VM 分別啟動 etcd，以下以 VM1 為例：

```bash
docker compose --env-file env/vm1.env -f compose/etcd-compose.yaml up -d
docker compose --env-file env/vm1.env -f compose/etcd-compose.yaml exec etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
docker compose --env-file env/vm1.env -f compose/etcd-compose.yaml exec etcd etcdctl --endpoints=http://127.0.0.1:2379 member list
```

VM2、VM3 將命令的 env 檔換成自己的檔案。至少兩個成員可互連後才能形成 quorum；不要在只啟動第一台時等待三台全部健康才啟動下一台。確認三台健康後，依 `POSTGRES.md` 啟動資料庫，再依 `APP.md` 啟動入口。

## 網路與資料

- TCP 2379：只允許三台 VM 存取，供 Patroni 與 etcd client 使用。
- TCP 2380：只允許三台 VM 互通，供 etcd peer 使用。
- etcd data 存於各 VM 自己的 `etcd-data` named volume，不共用磁碟。
- 這套實驗設定使用私有網路 HTTP，尚未配置 etcd TLS／驗證；正式部署需另行設計。

`ETCD_INITIAL_CLUSTER_STATE=new` 用於全新叢集；保留資料的正常重啟可以沿用。替換或新增成員必須使用 etcd membership 流程，不能只修改初始清單或複製別人的 data volume。

## 停止

```bash
docker compose --env-file env/vm1.env -f compose/etcd-compose.yaml stop etcd
```

一次維護一個成員，保留另外兩個在線。不要執行 `down -v`，除非確定要刪除該 VM 的叢集資料。

目前只驗證 Compose 設定結構；ARM64 建置、VM 網路與故障演練留待三台 VM 建好後執行。
