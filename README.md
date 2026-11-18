# Soft-delete aware unique constraint

A soft-deleted row still occupies its unique key. So the obvious `UNIQUE (account_id, slug)` blocks you from ever recreating something a user deleted — and the obvious workaround ("NULL doesn't equal NULL") only works if the constrained column itself is NULL.

The fix is a generated column that projects soft-deleted rows to NULL, so the index only covers live rows.

## The repro

```bash
mysql --table --force < examples/repro.sql
```

Actual output, MySQL 8.4.13 (Ubuntu 26.04, WSL), 2026-11-18:

```text
ERROR 1062 (23000) at line 24: Duplicate entry '1-demo' for key 'projects.uk_projects_account_slug_live'
+----+------------+------+------+-----------+
| id | account_id | slug | live | slug_live |
+----+------------+------+------+-----------+
|  1 |          1 | demo |    0 | NULL      |
|  3 |          1 | demo |    1 | demo      |
+----+------------+------+------+-----------+
ERROR 1062 (23000) at line 43: Duplicate entry '1-demo' for key 'projects_naive.uk_naive'
```

Three things are happening in that log:

1. **Line 24** — a second *live* row with the same slug is refused. That is the constraint doing its job.
2. **Rows 1 and 3** — the deleted row kept `slug = 'demo'` but its projected `slug_live` is `NULL`, so the live row could be created again.
3. **Line 43** — the same sequence against a naive `UNIQUE (account_id, slug)` fails. The dead row still holds the key.

## The DDL

```sql
ALTER TABLE projects
  ADD COLUMN slug_live VARCHAR(100)
    GENERATED ALWAYS AS (IF(deleted_at IS NULL, slug, NULL)) VIRTUAL,
  ADD UNIQUE KEY uk_projects_account_slug_live (account_id, slug_live);
```

Two details that bite:

- **Match the length.** `VARCHAR(100)` must equal the source column's length, or MySQL refuses the index with an unhelpful message.
- **Do not add `ALGORITHM=INPLACE`.** It fails with `ERROR 1846 … INPLACE ADD or DROP of virtual columns cannot be combined with other ALTER TABLE actions`. Let it take the default (COPY); on a small table it is seconds.

## Before you run that DDL

| Check | Why | Command |
|:--|:--|:--|
| `SELECT *` anywhere? | A virtual column adds a column to `*`, so positional `Scan` shifts | `grep -rn "SELECT \* FROM projects" .` |
| Dynamic INSERT from `INFORMATION_SCHEMA`? | Generated columns are not writable; MySQL raises 3105 | `grep -rn "INFORMATION_SCHEMA" .` |
| Existing duplicates among **live** rows? | The index will refuse to build | `SELECT account_id, slug, COUNT(*) FROM projects WHERE deleted_at IS NULL GROUP BY 1,2 HAVING COUNT(*) > 1;` |
| Backup taken? | This is DDL | `mysqldump projects \| gzip > projects.sql.gz` |

The first row is the one people skip. A generated column changes the shape of `SELECT *`, and hand-written positional scans break silently.

## Handle 1062 in the write path

A DB constraint alone gives users a 500 with MySQL's English in it. Map it:

```go
if err != nil {
    if strings.Contains(err.Error(), "Duplicate entry") || strings.Contains(err.Error(), "1062") {
        return 0, fmt.Errorf("slug %q already exists for this account — refresh and retry", slug)
    }
    return 0, err
}
```

And enumerate **every** INSERT into the table. Two write paths, one patched, is the same as neither patched.

## Verify all three properties

```sql
-- 1) live duplicate is refused
START TRANSACTION;
INSERT INTO projects (account_id, slug) VALUES (1,'demo');
ROLLBACK;   -- expect ERROR 1062

-- 2) a soft-deleted row does not block re-creation
START TRANSACTION;
UPDATE projects SET deleted_at = NOW() WHERE account_id = 1 AND slug = 'demo' AND deleted_at IS NULL;
INSERT INTO projects (account_id, slug) VALUES (1,'demo');
ROLLBACK;   -- expect success

-- 3) the index only covers live rows
SELECT COUNT(*) FROM projects WHERE slug_live IS NOT NULL;   -- equals live row count
```

A concurrency probe (multiple simultaneous inserts, exactly one row lands, the rest get 1062) is the only test that proves the "concurrent submit" case. Use `xargs -P 8` rather than shell `&` — many terminals and CI wrappers reject background jobs.

## License

MIT — see [LICENSE](LICENSE).
