-- Minimal "todo app" schema.
-- NOTE: todos.user_id intentionally has NO index, even though it is a
-- foreign key. This is a very common real-world mistake (Postgres does
-- NOT auto-create an index on FK columns) and is the bug this lab asks
-- you to find.

CREATE TABLE users (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE todos (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id),
    title      TEXT NOT NULL,
    completed  BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- 100,000 users
INSERT INTO users (name, email, created_at)
SELECT
    'user_' || i,
    'user_' || i || '@example.com',
    now() - (random() * interval '400 days')
FROM generate_series(1, 100000) AS i;

-- 10,000,000 todos spread randomly across users.
-- This takes roughly 1-2 minutes on first container start.
INSERT INTO todos (user_id, title, completed, created_at)
SELECT
    (random() * 99999 + 1)::bigint,
    'todo_' || i,
    (random() < 0.5),
    now() - (random() * interval '400 days')
FROM generate_series(1, 10000000) AS i;

ANALYZE users;
ANALYZE todos;
