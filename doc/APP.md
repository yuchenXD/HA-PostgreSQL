# app.yaml：Application VM 的資料庫入口

對應 `compose/app.yaml` 與 `compose/haproxy.cfg`，部署於 VM1。先依 `ETCD.md` 啟動三個 etcd，再依 `POSTGRES.md` 啟動資料庫。

Application 的 Image、埠與啟動方式尚未指定，本階段 `app.yaml` 只建立 HAProxy。後續可以加入 Application service；若使用 bridge network，直接連線至 VM1 的私有 IP 與 5000 埠即可。

## 啟動

在 VM1 的 `env/vm1.env` 設定實際位址：

- `APP_VM_IP`：VM1 的私有 IP，HAProxy 綁定此位址的 TCP 5000。
- `PG_NODE_1_IP`：VM2 的私有 IP。
- `PG_NODE_2_IP`：VM3 的私有 IP。

```bash
docker compose --env-file env/vm1.env -f compose/etcd.yaml -f compose/app.yaml up -d --wait
docker compose --env-file env/vm1.env -f compose/etcd.yaml -f compose/app.yaml ps
```

HAProxy 以 HTTP `/primary` 檢查兩個 Patroni 的 8008 埠，僅將新 SQL 連線送往回傳 HTTP 200 的 Primary。此端點用於角色檢查，不需把 Patroni 管理密碼放入 HAProxy。

Application 的資料庫 host 設為 `APP_VM_IP`、port 設為 `5000`；資料庫與應用程式帳號要在後續建立，不預設讓 Application 使用資料庫 superuser。切換後既有連線可能斷線，Application 必須支援重連，且依交易結果決定能否重試。

可以使用已安裝的 PostgreSQL client 測試實際帳號登入，密碼由互動提示輸入：

```bash
psql -h <VM1_PRIVATE_IP> -p 5000 -U <DATABASE_USER> -d <DATABASE_NAME> -W
```

## 維護與限制

```bash
docker compose --env-file env/vm1.env -f compose/etcd.yaml -f compose/app.yaml stop haproxy
```

VM1 的 TCP 5000 僅允許 Application 或指定管理來源。VM1 上的 Application 與 HAProxy 仍是單點，VM1 故障時即使資料庫仍有 Primary，應用入口也會中斷。三台 VM 同在一台 Mac，只能演練 VM 層級故障，不能抵抗整台 Mac 故障。

目前只驗證 Compose 與 HAProxy 設定結構；沒有啟動單機叢集或進行跨 VM 路由測試。
