# Repository Guidelines

## Project Structure

This repository deploys PostgreSQL HA across three Linux VMs using Docker Compose and host networking. The deployment files are in `compose/`, mounted service settings are in `config/`, environment templates are in `env/`, and the PostgreSQL/Patroni Dockerfile is in `image/`. The service runbooks are in `doc/`. Image publishing and smoke tests live in `.github/workflows/`.

## Lab VM Topology

| VM | Private IP | Services |
| --- | --- | --- |
| `lab_ubuntu_node_1` | `192.168.230.150` | PostgreSQL, Patroni, etcd |
| `lab_ubuntu_node_2` | `192.168.230.151` | PostgreSQL, Patroni, etcd |
| `lab_ubuntu_node_3` | `192.168.230.152` | HAProxy, etcd |

All three VMs use the SSH account `adam`. The shared VM login password is stored in `VM_SSH_PASSWORD` in `codex/.env.vm-login`, a local file ignored by Git. For lab operations, use the VM names and service roles in the table. On VM3, set `PG_NODE_1_IP` to `192.168.230.150`, `PG_NODE_2_IP` to `192.168.230.151`, and `VM_IP` to `192.168.230.152`. Compose passes `VM_IP` to HAProxy as `APP_VM_IP`.

## Build and Run

Run commands from the repository root. Build the default database image with Docker.

```sh
docker build -t yuchen1226/postgres-patroni:18.6-patroni4.1.5 image
```

For a fresh install, copy `env/postgres.env.example` to `compose/.env` on VM1 and VM2. Apply the VM2 values from `doc/POSTGRES.md` on VM2, and use the same Patroni credentials on both database VMs. On VM3, copy `env/app.env.example` to `compose/.env`. Follow `doc/ETCD.md`, `doc/POSTGRES.md`, and `doc/APP.md` in that order. Use one Compose file per command to preserve the separate etcd and PostgreSQL/HAProxy project names.

## Style and Configuration

Use two-space YAML indentation, `<service>-compose.yaml` for deployment filenames, and uppercase underscore-separated environment names. Update the Compose files, environment examples, and runbooks together when changing image tags, ports, or node mappings. Keep real environment files, credentials, database backups, and local image archives out of commits.

## Validation

Validate Compose changes with the sample files before deploying. For example, check PostgreSQL with the VM1 template.

```sh
docker compose --env-file env/postgres.env.example -f compose/postgres-compose.yaml config --quiet
```

Check etcd on all three VMs, PostgreSQL with the VM1 and VM2 settings, and HAProxy with the App template. For lab checks, run `etcdctl endpoint health` on all three VMs and `patronictl list` on the database VMs. Test SQL with `psql` through HAProxy at `192.168.230.152:5000`. The publishing workflow smoke-tests Patroni and its dependencies on AMD64 and ARM64.

## Commit Messages

Use `<type>: <summary>` for the subject, with a lowercase type and a single space after the colon. Start the English summary with an imperative verb, keep it to one line, and omit the trailing period. Preserve the capitalization of names such as PostgreSQL and Docker Hub.

| Type | Use | Example from this repository |
| --- | --- | --- |
| `feat` | Add a feature or deployment capability | `feat: add PostgreSQL 18 and Patroni image` |
| `fix` | Correct an existing problem | `fix: smoke test platform manifests independently` |
| `refactor` | Reorganize implementation or configuration | `refactor: separate Compose files from service configuration` |
| `ci` | Change CI or image publishing workflows | `ci: restrict Docker Hub publishing to main` |
| `chore` | Maintain project files or directory structure | `chore: add initial project directory structure` |

When the subject needs more context, leave a blank line and add a body. Explain why the change was made and include relevant validation or effects on existing clusters.

## Pull Requests

In pull requests, describe the change, name the affected VMs or services, and list the checks you ran. Link the issue when applicable and call out any effects on existing clusters.
