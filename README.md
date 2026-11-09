# sitetrack-backend

Backend API for SiteTrack, a construction project and materials tracker, written in Dart with PostgreSQL.

Work in progress.

## Run it

```sh
docker compose up
```

This builds the API image, starts Postgres 18 and the API, and applies the schema. The API listens on
<http://localhost:8080> (set `API_PORT` to use another host port); `GET /health` answers once it is ready.
Postgres is not published to the host; use `docker compose exec db psql -U sitetrack` to look inside.

`docker compose down -v` stops everything and deletes the data.

## Layout

```
bin/server.dart          entrypoint: wait for Postgres, migrate, serve
lib/src/app.dart         routes and middleware
lib/src/config.dart      settings from environment variables
lib/src/db/              connection pool and the migration runner
lib/src/http/            JSON helpers, error responses, middleware
migrations/NNNN_*.sql    the schema, as plain SQL applied in order on startup
```

## Schema

`migrations/0001_initial_schema.sql` holds the data model, with the reasoning next to each table. In short:

- **IDs.** Project numbers come from a row-locked counter, task numbers from a counter on the project row. Both are
  unique under concurrent creates and never reused. `PRJ-0042` and `PRJ-0042-T-0137` are derived from the integers
  by `project_code()` and `task_code()`, never stored.
- **Dependencies** are keyed by `(project_id, task_number, depends_on_number)` with composite foreign keys, so a
  dependency between two projects cannot be stored at all.
- **Blocked** is stored per task and recomputed for the whole project (at most a few thousand tasks) by
  `refresh_project_task_stats()` inside every transaction that changes tasks or dependencies. The same call keeps
  the per-project task counters, so the projects screen never aggregates 500,000 tasks. **Late** depends on
  today's date, so it is computed when read, helped by two partial indexes.
- **Stores.** The company store is the `company_stock` table (one row per material); a project's store is its rows
  in `project_stock`. A delivery has a project and a direction, so project-to-project deliveries cannot be expressed.
  Quantities are exact decimals with `CHECK (quantity >= 0)`.
