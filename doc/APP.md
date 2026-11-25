# app-compose.yaml：Application VM 的資料庫入口

對應 `compose/app-compose.yaml` 與 `config/haproxy.cfg`，部署於 VM3（192.168.230.152）。先依 `ETCD.md` 啟動三個 etcd，再依 `POSTGRES.md` 啟動資料庫。

目前 `app-compose.yaml` 啟動 HAProxy。使用 bridge network 的 Application 可以連至 VM3 的私有 IP 與 5000 埠。

## 啟動

VM3 按 `env/app.env.example` 設定 `compose/.env`：

- `VM_IP` 為 VM3 的私有 IP。Compose 將它傳入 HAProxy 的 `APP_VM_IP`，用於綁定 TCP 5000。
- `PG_NODE_1_IP` 為 VM1 的私有 IP。
- `PG_NODE_2_IP` 為 VM2 的私有 IP。

HAProxy 設定不含帳密，啟動前允許容器讀取掛載檔：

```bash
chmod 644 config/haproxy.cfg
```

```bash
docker compose --env-file compose/.env -f compose/app-compose.yaml up -d --wait
docker compose --env-file compose/.env -f compose/app-compose.yaml ps
```

HAProxy 以 HTTP `/primary` 檢查兩個 Patroni 的 8008 埠，僅將新 SQL 連線送往回傳 HTTP 200 的 Primary。此端點用於角色檢查，不需把 Patroni 管理密碼放入 HAProxy。

Application 的資料庫 host 設為 `192.168.230.152`、port 設為 `5000`，並使用自己專用的資料庫帳號。切換後既有連線可能斷線，Application 必須支援重連，且依交易結果決定能否重試。

可以使用已安裝的 PostgreSQL client 測試實際帳號登入，密碼由互動提示輸入：

```bash
psql -h 192.168.230.152 -p 5000 -U <DATABASE_USER> -d <DATABASE_NAME> -W
```

## 維護與限制

```bash
docker compose --env-file compose/.env -f compose/app-compose.yaml stop haproxy
```

VM3 的 TCP 5000 僅允許 Application 或指定管理來源。HAProxy 是單點，VM3 故障時應用入口會中斷。三台 VM 同在一台 Mac，適合演練 VM 層級故障。
