FROM postgres:18.6-trixie@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42

ARG PATRONI_VERSION=4.1.5

# Optional build-only CA for HTTPS-inspecting proxies; never stored in the image.
# 可選的代理伺服器 CA 憑證，供 HTTPS 檢查環境於建置時使用，不會存入 Image。
RUN --mount=type=secret,id=proxy_ca \
    set -eux; \
    if [ -f /run/secrets/proxy_ca ]; then \
        export PIP_CERT=/run/secrets/proxy_ca; \
    fi; \
    # Only Debian repositories are needed for the Python runtime.
    # 安裝 Python 執行環境只需要 Debian 套件來源。
    apt-get -o Dir::Etc::sourcelist=sources.list.d/debian.sources \
        -o Dir::Etc::sourceparts=- update; \
    apt-get install -y --no-install-recommends \
        ca-certificates python3 python3-venv; \
    python3 -m venv /opt/patroni; \
    /opt/patroni/bin/pip install --no-cache-dir \
        "patroni[etcd3,psycopg3]==${PATRONI_VERSION}"; \
    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18/docker; \
    install -d -o postgres -g postgres -m 0755 /etc/patroni; \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/patroni/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER postgres

EXPOSE 5432 8008

# Patroni receives SIGTERM and manages PostgreSQL shutdown.
# 由 Patroni 接收 SIGTERM，並負責正常關閉 PostgreSQL。
STOPSIGNAL SIGTERM

# Mount the node configuration here; Patroni also owns database initialization.
# 啟動時將節點設定檔掛載至下方路徑，資料庫初始化也由 Patroni 負責。
ENTRYPOINT ["patroni"]
CMD ["/etc/patroni/patroni.yml"]
