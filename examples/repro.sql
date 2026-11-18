-- Soft-delete aware unique constraint — minimal reproduction
-- Run: mysql --table < examples/repro.sql
--
-- Expected (see the run log in README):
--   1) two live rows with the same slug  -> ERROR 1062
--   2) delete one, create it again       -> succeeds (soft-deleted row does not block)
--   3) duplicate soft-deleted rows       -> allowed (they project to NULL)

DROP DATABASE IF EXISTS softdel; CREATE DATABASE softdel; USE softdel;

CREATE TABLE projects (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id BIGINT UNSIGNED NOT NULL,
  slug       VARCHAR(100)    NOT NULL,
  deleted_at DATETIME        NULL,
  -- projection: live rows keep the slug, soft-deleted rows become NULL
  slug_live  VARCHAR(100) GENERATED ALWAYS AS (IF(deleted_at IS NULL, slug, NULL)) VIRTUAL,
  UNIQUE KEY uk_projects_account_slug_live (account_id, slug_live)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO projects (account_id, slug) VALUES (1, 'demo');

-- 1) the same live slug twice is refused
INSERT INTO projects (account_id, slug) VALUES (1, 'demo');

-- 2) soft delete, then create the same slug again
UPDATE projects SET deleted_at = NOW() WHERE account_id = 1 AND slug = 'demo' AND deleted_at IS NULL;
INSERT INTO projects (account_id, slug) VALUES (1, 'demo');

-- 3) what the table looks like now: one live, one deleted
SELECT id, account_id, slug, deleted_at IS NULL AS live, slug_live FROM projects ORDER BY id;

-- 4) the naive constraint, for contrast: same thing without the generated column
CREATE TABLE projects_naive (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  account_id BIGINT UNSIGNED NOT NULL,
  slug VARCHAR(100) NOT NULL,
  deleted_at DATETIME NULL,
  UNIQUE KEY uk_naive (account_id, slug)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO projects_naive (account_id, slug) VALUES (1,'demo');
UPDATE projects_naive SET deleted_at = NOW() WHERE id = 1;
INSERT INTO projects_naive (account_id, slug) VALUES (1,'demo');  -- fails: the dead row still holds the key
