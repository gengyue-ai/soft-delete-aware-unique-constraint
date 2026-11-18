---
name: soft-delete-aware-unique-constraint
description: Use when adding a UNIQUE index to a soft-deleted table, or when users report "I deleted it and cannot create it again". Generated column projects dead rows to NULL so the index only covers live rows.
---

## When to use

- A table soft-deletes with `deleted_at` and needs `UNIQUE (owner_id, slug)`.
- Users report: "I deleted it, now it says it already exists."
- You are deciding between "clean up duplicate rows" and "change the constraint design".

## First principle: the liveness test is `deleted_at IS NULL`

Not `status <> 'deleted'`. In one real table the `status` enum never contained a `deleted` value at all — soft delete only wrote `deleted_at`. Counting with the wrong predicate turned 13 deleted rows into "13 live duplicates" and produced the wrong conclusion ("we must clean data before adding the index").

```sql
-- must return zero rows before you touch the schema
SELECT owner_id, slug, COUNT(*) FROM projects
 WHERE deleted_at IS NULL
 GROUP BY owner_id, slug HAVING COUNT(*) > 1;

-- liveness count should equal distinct-key count
SELECT SUM(deleted_at IS NULL), COUNT(*) FROM projects;
```

## Why a plain UNIQUE fails

1. Deleted rows keep their key values, so a hard constraint blocks legitimate re-creation.
2. "NULL never equals NULL, so the index ignores deleted rows" is only true if the *constrained column itself* is NULL.

So project the deleted rows to NULL:

```sql
ALTER TABLE projects
  ADD COLUMN slug_live VARCHAR(100)
    GENERATED ALWAYS AS (IF(deleted_at IS NULL, slug, NULL)) VIRTUAL,
  ADD UNIQUE KEY uk_projects_owner_slug_live (owner_id, slug_live);
```

- Match the source column's `VARCHAR` length exactly.
- Do **not** add `ALGORITHM=INPLACE`: it errors with 1846 for virtual columns. Default (COPY) is fine for small tables.

## Three checks before the DDL

1. `SELECT *` on this table anywhere? A virtual column adds one to `*`, so positional `Scan`/`rows[i]` shifts. `grep -rn "SELECT \* FROM projects" .`
2. Any INSERT built from `INFORMATION_SCHEMA`? Generated columns are not writable (MySQL 3105).
3. Backup: `mysqldump projects | gzip > projects.sql.gz`.

## Map 1062 in every write path

```go
if err != nil && (strings.Contains(err.Error(), "Duplicate entry") || strings.Contains(err.Error(), "1062")) {
    return 0, fmt.Errorf("slug %q already exists for this account — refresh and retry", slug)
}
```

Enumerate every INSERT into the table. Patching one of two paths is the same as patching none.

## Verify three properties, not one

1. Live duplicate refused (`START TRANSACTION; INSERT ...; ROLLBACK;` → 1062).
2. Deleted row does not block re-creation (same transaction trick → success).
3. `SELECT COUNT(*) WHERE slug_live IS NOT NULL` equals the live row count.

Concurrency (many simultaneous inserts, exactly one row lands) needs a real parallel probe — `xargs -P 8`, not shell `&`.
