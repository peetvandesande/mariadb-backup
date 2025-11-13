# PostgreSQL Backup & Restore Guide

This guide explains how to use **pg-backup** to safely back up and restore PostgreSQL databases running in Docker.

---

## 🎯 What This Handles

- Dumps your PostgreSQL database using `pg_dump`
- Supports compressed output (`gz`, `bz2`, `zst`) or plain `.sql`
- Can verify integrity with `.sha256` checksums
- Can **automatically restore the newest dump**

This container does **not** run PostgreSQL itself — it only uses client tools.

---

## 🧱 Backup Example (Nextcloud DB)

```bash
docker run --rm \
  -v /var/backups:/backups \
  -e POSTGRES_HOST=nextcloud-db \
  -e POSTGRES_USER=nextcloud \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=nextcloud \
  -e BACKUP_NAME_PREFIX=nextcloud-db \
  -e RUN_ONCE=1 \
  peetvandesande/pg-backup:alpine
```

---

## 🔄 Restore Procedure (Important!)

### 1) Ensure volumes and containers exist, but do **not** start services yet

```bash
docker compose up --no-start
```

This safely creates:
- Networks  
- Volumes  
- Container definitions  
…but **does not launch the application** (correct stage for restore).

### 2) Restore latest database dump

```bash
docker run --rm \
  -v /var/backups:/backups \
  -e POSTGRES_HOST=nextcloud-db \
  -e POSTGRES_USER=nextcloud \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=nextcloud \
  -e BACKUP_NAME_PREFIX=nextcloud-db \
  peetvandesande/pg-backup:alpine restore
```

### 3) Start services

```bash
docker compose up -d
```

---

## ✅ Checklist After Restore

| Check | How |
|------|-----|
| DB structure correct | `psql \d` |
| Users present | Login to application |
| Shared links working | Test UI |
| No upgrade screen | Versions match |

If you restored DB from a **newer** Nextcloud version → you will see the upgrade screen. Restore matching versions.

---
