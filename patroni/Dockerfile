FROM postgres:18

# PostgreSQL 18 + Patroni (etcd v3, psycopg3)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3 python3-venv ca-certificates; \
    python3 -m venv /opt/patroni; \
    /opt/patroni/bin/pip install --no-cache-dir 'patroni[etcd3,psycopg3]==4.1.5'; \
    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18/docker; \
    mkdir -p /etc/patroni; \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/patroni/bin:${PATH}"

USER postgres

# Patroni receives shutdown signals and stops PostgreSQL.
STOPSIGNAL SIGTERM

EXPOSE 5432 8008
ENTRYPOINT ["patroni"]
CMD ["/etc/patroni/patroni.yml"]
