# PostgreSQL YCSB on SwornDisk/CryptDisk (short)

Minimal steps to spin up two isolated PostgreSQL instances (SwornDisk 5433, CryptDisk 5434) and run go-ycsb workloads.

## Prereqs

- Ubuntu/Debian: `sudo apt update && sudo apt install -y postgresql postgresql-contrib`
- go-ycsb built (run `make` in go-ycsb or use top-level setup.sh)
- Filesystems mounted at `/mnt/sworndisk` and `/mnt/cryptdisk` (see mount_filesystems.sh)

## One-shot workflow

```bash
# init and start instances, create test db/user
./configure_postgres.sh init sworndisk
./configure_postgres.sh start sworndisk
./configure_postgres.sh init-ycsb sworndisk

./configure_postgres.sh init cryptdisk
./configure_postgres.sh start cryptdisk
./configure_postgres.sh init-ycsb cryptdisk

# run workloads a/b/e/f on both instances, write postgres_results.json
./run_postgres_benchmark.sh

# inspect results
cat postgres_results.json
```

## Key commands

- Init: `./configure_postgres.sh init {sworndisk|cryptdisk}`
- Start/Stop: `./configure_postgres.sh {start|stop} {sworndisk|cryptdisk}`
- Init YCSB db/user: `./configure_postgres.sh init-ycsb {sworndisk|cryptdisk}` (creates db=test, user=root/root)
- Status: `./configure_postgres.sh status [sworndisk|cryptdisk]`
- Clean (wipe data): `./configure_postgres.sh clean {sworndisk|cryptdisk}`

## Bench config (defaults in scripts)

- Data dirs: `/mnt/sworndisk/ycsb/postgres`, `/mnt/cryptdisk/ycsb/postgres`
- Ports: 5433 (SwornDisk), 5434 (CryptDisk)
- Workloads: workloada, workloadb, workloade, workloadf
- Output: `postgres_results.json`

## Quick fixes

- Postgres missing: `sudo apt install -y postgresql postgresql-contrib`
- Instance not running: `./configure_postgres.sh start sworndisk` (or cryptdisk)
- DB not initialized: `./configure_postgres.sh init-ycsb sworndisk`
- Port in use: adjust port variables at top of [configure_postgres.sh](configure_postgres.sh)

For deeper tuning or manual SQL, open [configure_postgres.sh](configure_postgres.sh) and [run_postgres_benchmark.sh](run_postgres_benchmark.sh).
