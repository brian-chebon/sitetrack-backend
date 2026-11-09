# SiteTrack backend

The API for SiteTrack, a construction project and materials tracker: projects and their teams, tasks with
dependencies, a company store and project stores, and the deliveries that move material between them.
Written in Dart with PostgreSQL.

- [Run it](#run-it)
- [First, one decision you should know about](#first-one-decision-you-should-know-about)
- [How the rules are enforced](#how-the-rules-are-enforced)
- [Performance at the brief's scale](#performance-at-the-briefs-scale)
- [Decisions](#decisions)
- [Trade-offs I accepted](#trade-offs-i-accepted)
- [What I would change or add with more time](#what-i-would-change-or-add-with-more-time)
- [Code layout](#code-layout)

## Run it

```sh
docker compose up
```

That builds the API, starts Postgres 18 and the API, and applies the schema. The API is on
<http://localhost:8080> (set `API_PORT` for another port), ready when `GET /health` answers.

| | |
|---|---|
| **API documentation** | <http://localhost:8080/docs> (OpenAPI 3.1, file in [`docs/openapi.yaml`](docs/openapi.yaml)). It opens with the sign-in flow, the access rules, and a table mapping each screen in the brief to its calls. |
| **Load data at scale** | `docker compose run --rm seed` fills the database with the brief's test volumes in about three minutes (`--scale 0.1` for a tenth, `--reset` to wipe and reload). |
| **Seeded logins** | Password `sitetrack-demo` for every seeded account. `superadmin@sitetrack.test` (SuperAdmin), `manager@sitetrack.test` (store manager), `user@sitetrack.test` (member of every 50th project, admin of every 100th, with open invitations). |
| **Tests** | `docker compose run --rm test`: 57 integration tests against a real Postgres. Each test file creates and drops its own database. With a local Dart SDK, `dart test` uses `TEST_DATABASE_URL` (default: a Postgres on `127.0.0.1:55432` with user and password `sitetrack`, e.g. `docker run -d -p 127.0.0.1:55432:5432 -e POSTGRES_USER=sitetrack -e POSTGRES_PASSWORD=sitetrack postgres:18-alpine`). |
| **Benchmark** | `docker compose run --rm test dart run tool/bench.dart` times every screen against the seeded API. |
| **Look inside** | `docker compose exec db psql -U sitetrack`. Postgres is not published to the host, so a local Postgres cannot clash. |
| **Stop** | `docker compose down` (add `-v` to delete the data). |

Settings, all optional: `APP_TIMEZONE` (the calendar that decides "today" for Late tasks; default `UTC`),
`JWT_SECRET` (random per start if unset, see below), `BCRYPT_COST` (default 10), `DB_POOL_SIZE` (default 10),
`LOG_REQUESTS=false`.

## First, one decision you should know about

**Anyone can register as a SuperAdmin.** The brief has people choose their app role when they register, and I
built it that way, because the screens and any test scripts depend on it. But it means the role system protects
nothing from someone who simply signs up as SuperAdmin, which works against "people must only ever reach the data
their app role allows".

What I added: SuperAdmins can change anyone's app role (`PATCH /v1/users/{id}/role`), and the change applies to
that person's very next request. The last SuperAdmin cannot be demoted.

What I would ship for real: registration creates plain Users only; the first SuperAdmin is created from deployment
settings (or a one-off command); store managers and further SuperAdmins are appointed with that endpoint. It is a
small change (the role field on the register screen goes away), and I would make it as soon as the brief allows.

## How the rules are enforced

### Access, on every request

- **Sign-in.** Login returns a 15-minute HS256 access token naming a server-side session, plus a refresh token.
  The frontend refreshes before expiry; each refresh replaces the refresh token and extends the session by
  7 days, up to 30 days after login. So people who keep using the app are never sent back to the login screen.
- **Every request is re-checked against the database.** The authentication middleware loads the session and the
  caller's current role in one primary-key query. Logging out revokes that session row, so its token stops
  working immediately. A role change, or a removal from a project, applies on the next request, because
  neither is ever read from the token.
- **One gate for projects.** Every project route goes through
  [`loadProject()`](lib/src/projects/project_access.dart), which only finds a project the caller is a member of,
  or any project for a SuperAdmin. Everything else gets the same 404, byte for byte: a real project, a made-up ID,
  a removed project, a malformed ID. So a response never confirms that a project ID exists. The visibility test
  is part of the locking query itself, so someone who cannot see a project cannot even hold its lock.
- **Lists only contain what the caller may see.** The projects screen query starts from the visible projects, so
  every count, search, filter and sort runs over those alone. Everything inside a project is reached through
  that project.
- **Other boundaries.** Inside a project, members work with tasks, the store and deliveries; only project admins
  change the project, its members and its invitations (403 for other members, who already know the project
  exists). Only the invitee can answer an invitation; for anyone else it does not exist. The company store
  answers 403 to everyone but store managers and SuperAdmins. The people directory only lists the caller's
  colleagues (people who share a project with them); a stranger is found only by their exact email.
- **Passwords** are bcrypt-hashed (cost 10, on a worker isolate so hashing never stalls other requests) and never
  returned. A login with an unknown email does the same bcrypt work as one with a wrong password, and both get
  the same 401. Ten failures for one email within 15 minutes lock that email out until the oldest failure
  is 15 minutes old, whether or not the email is registered.

### IDs

Project numbers come from a single counter row, `UPDATE counters ... RETURNING`, inside the transaction that
creates the project. The row lock makes simultaneous creates queue for a moment and get consecutive numbers. A
rolled-back create gives its number back, and nothing ever decrements the counter, so numbers are never reused.
Task numbers work the same way, from a counter on the project row. `PRJ-0042` and `PRJ-0042-T-0137` are derived
from the integers and never stored. Tests create 25 projects and 20 tasks in parallel and check the numbers
come out unique and consecutive.

### Dependencies and status

- Dependencies are stored as `(project_id, task_number, depends_on_number)` with two composite foreign keys, so a
  dependency between projects cannot even be stored.
- A new dependency is refused when the other task already waits on this one, directly or through other tasks. A
  recursive query walks upstream from it, visiting each task once.
- Every change to a project's tasks or dependencies takes the project row lock first. So two requests closing a
  loop from both ends at the same moment cannot both pass; a test fires exactly that.
- **Blocked** is stored per task and recomputed for the whole project by
  [`refresh_project_task_stats()`](migrations/0001_initial_schema.sql) at the end of every such transaction, along
  with the project's task counts. A project has at most a few thousand tasks, so this costs a few milliseconds,
  and recounting cannot drift the way +1/−1 counters can.
- **Late** depends on today's date, so it is computed when read. Since start ≤ end, a task that has not started is
  late once its start date has passed, and a task in progress once its end date has. Two small partial indexes
  answer "late tasks per project" for all 2,000 projects at once.
- **Start** needs everything upstream to be done, **Mark as done** needs In progress, and **Reopen** needs everything
  downstream to be Not started. Any other change is refused with `invalid_transition`. Task details list the
  actions allowed right now.

### Stock and deliveries

- There is one stock row per material in the company store and one per (project, material) in each project
  store. A delivery has a project and a direction, so a project-to-project delivery cannot be expressed.
- **No store ever goes negative, even under concurrent deliveries.** Every movement first locks the stock rows it
  touches, in material order, then checks the quantities under that lock, then applies all its lines in one
  transaction. `CHECK (quantity >= 0)` is the backstop.
- **Each delivery ends exactly once.** Recording, rejecting or cancelling locks the delivery row first, so of a
  record and a cancel racing, exactly one wins.
- **No deadlocks.** Every operation takes its locks in the same order: project, materials, delivery, company
  stock, project stock.
- **Tested under load:** 25 parallel one-unit sends from a store holding ten (exactly ten succeed, stock ends at
  0), record racing cancel, and multi-line sends locking the same materials in opposite orders.

## Performance at the brief's scale

`docker compose run --rm seed` loads at least the brief's volumes: 5,000 users; 2,000 projects of up to
50 members; 50,040 invitations; 500,000 tasks, with ten projects of exactly 3,000; 1,041,272 dependencies;
20,000 materials; 400,000 deliveries holding 3,031,922 lines.

The seeded data also obeys every rule the API enforces, so the API can be judged against it:

- Tasks only wait on earlier tasks of their own project.
- Statuses follow each project's progress through its dates, so nothing that has started waits on anything
  unfinished, and projects running behind schedule have late tasks.
- Returns carry back at most 30% of a line the project received.
- Every store's stock, and the supplier stock additions behind it, are derived from that delivery history.

The seeder checks those invariants and every foreign key at the end. The whole database is about 700 MB.

Every screen, measured over HTTP against that data. The client ran on the same 8-core machine as the compose
stack, with Postgres configured as in `docker-compose.yml` for a small server (1 GB shared buffers, JIT off).
The figures are milliseconds over 15 runs after a warm-up:

| Screen | Call | Median | Slowest |
|---|---|---:|---:|
| 3 Notifications | list, as user | 9 | 11 |
| 3 Notifications | unread count (header badge) | 5 | 6 |
| 4 Projects | all 2,000, as SuperAdmin, by name | 38 | 51 |
| 4 Projects | all 2,000, by % done | 31 | 42 |
| 4 Projects | all 2,000, by late tasks | 32 | 43 |
| 4 Projects | only with late tasks | 33 | 47 |
| 4 Projects | search "Muscat" | 28 | 35 |
| 4 Projects | as user (40 projects) | 11 | 14 |
| 5 Tasks | 3,000-task project, by ID | 17 | 27 |
| 5 Tasks | by dependents count | 18 | 22 |
| 5 Tasks | late and blocked | 8 | 11 |
| 5 Tasks | date range + search | 6 | 8 |
| 6 Task details | last task of a 3,000-task project (2,500 upstream) | 101 | 113 |
| 6 Task details | first task of a 3,000-task project (~3,000 downstream) | 108 | 133 |
| 6 Task details | ordinary project | 22 | 32 |
| 7 Project store | by last delivery | 9 | 10 |
| 7 Project store | search + category | 8 | 11 |
| 8 Project deliveries | newest first | 24 | 29 |
| 8 Project deliveries | incoming, delivered, 2025 | 20 | 26 |
| 9 Members | members + invitations | 6 | 12 |
| 10 Company stock | 20,000 materials by name | 23 | 29 |
| 10 Company stock | by status | 23 | 38 |
| 10 Company stock | low stock in one category | 16 | 24 |
| 10 Company stock | search "rebar" | 24 | 32 |
| 11 Company deliveries | newest first, of 400,000 | 17 | 21 |
| 11 Company deliveries | next page by cursor | 21 | 25 |
| 11 Company deliveries | in transit | 22 | 27 |
| 11 Company deliveries | one project, incoming | 14 | 18 |
| 11 Company deliveries | rejected, 2024 | 25 | 31 |

Writes in the largest projects take 110–170 ms: creating a task waiting on the last of 3,000, adding a dependency,
starting a task, marking it done. Most of that is the full task-details response they return; recomputing
Blocked is a few milliseconds. A refused loop through all 3,000 tasks takes 15 ms. Sending and recording
deliveries take about 20 ms. Login takes about 230 ms, which is bcrypt doing its job.

What keeps these fast: per-project counters (task counts by status, Blocked count, members), so the projects
screen never reads 500,000 tasks; partial indexes for Late; covering indexes on both directions of the
dependency graph; and keyset paging for the company-wide delivery list.

Company stock was the one slow screen at first, taking 50–70 ms. Its page query was computing `count(*) OVER ()`
and sorting all 20,000 rows to return 50. Migration 0003 and a two-query version brought every sort down to
about 20 ms. Responses of 8 KB or more are gzipped; the largest task-details response is 435 KB raw and 24 KB
compressed.

## Decisions

Everything the brief leaves open, with what I chose and why.

| Question | Decision | Why |
|---|---|---|
| Framework, database access | `shelf` + `shelf_router`; plain SQL through `package:postgres`, no ORM | Both are small, maintained by the Dart team, and stay out of the way. The SQL *is* the access control and the performance work, so it should be visible and reviewable, not generated. |
| Schema management | Numbered SQL files applied on API start, in one transaction, under an advisory lock, with checksums | `docker compose up` needs no extra step. Two API processes cannot migrate at once. An edited, already-applied migration stops startup instead of drifting silently. |
| API shape | REST under `/v1`; camelCase JSON; enum values in snake_case; errors as `{error: {code, message, details}}` | Stable `code`s let the frontend branch without parsing messages; a 400 lists every bad field at once. |
| Tokens | 15-minute access JWT plus a rotating refresh token; the session is checked on every request | The brief requires JWTs, instant logout and immediate effect of role and membership changes. A stateless JWT alone cannot give the last two. |
| JWT secret | Random at each start unless `JWT_SECRET` is set | No secret ships in the repo. After a restart clients just refresh: refresh tokens live in the database, not in the key. |
| Not found vs forbidden | 404 for anything in a project the caller cannot see; 403 for the company store and for member-but-not-admin actions | The brief requires projects to look nonexistent. The company store's existence is not a secret, and a member already knows the project exists. |
| What SuperAdmins may do | See and work in every project (tasks, store, deliveries), but not manage members or edit and remove projects unless they are its admin | "Every project … whether or not they are a member" is about access. "Only project admins change members, invitations and admin status" is explicit. |
| Who edits and removes a project | Its project admins | Same reasoning as members. |
| Removing a project | Refused while its store holds stock or a delivery is in transit; otherwise hidden for everyone, number kept, unanswered invitations withdrawn | Material only leaves a store by delivery, so it must be sent back first. The company store's delivery history still needs the project. |
| Removing a task | Refused while other tasks depend on it; its own dependencies go with it | Removing a prerequisite would silently unblock work. Making people unlink first keeps that deliberate. |
| Adding a dependency to a started task | Allowed only on a task that is already done | Otherwise a task could be under way, or finished, while something it waits on is not, which is what the Start rule exists to prevent. With this rule, "a started task's prerequisites are all done" always holds. |
| What "started" means for Reopen | In progress or Done | Both mean the work has begun. |
| Today, for Late | The date in `APP_TIMEZONE` (default UTC), set as the database session time zone | Late must be the same for every viewer, or the projects screen would sort differently per person. "Passed" means strictly before today. |
| Task date-range filter | Tasks whose planned period overlaps the range | It answers "what is planned between these dates". Delivery date filters use the date sent. |
| Unread notifications | Pending and not yet seen. Opening the screen calls `POST /v1/notifications/read`; answering marks one read; one withdrawn before it was seen stops counting | The badge should mean "something needs you". The count is in `GET /v1/me` and its own endpoint. |
| Finding people to invite | The directory searches you and the people you share a project with; anyone else is found, and invited, by their exact email. SuperAdmins search everyone | Admins may invite "any other registered user", and anyone can create a project and so become an admin. An open directory, or invites by any user ID, would let anyone who signs up list every registered email. |
| Leaving a project | Members can remove themselves; the last admin cannot leave, be removed or be demoted | Keeps the "at least one admin" rule while letting people leave. |
| Registration with a taken email | 409 `email_taken` | Unavoidable without email verification. The brief's rule is about login, where it is honoured. |
| Store managers and projects | They see every project's ID and name in the company store (to deliver to it), nothing inside it | Screen 11 has managers deliver to any project and filter by project. |
| Who maintains the catalogue | Everyone reads it; store managers and SuperAdmins create, edit and remove | They run the store the catalogue describes. |
| A material's unit | Fixed once any stock has been added; removal hides it from the catalogue (refused while any store holds it) | Recorded quantities and delivery lines are in the old unit. |
| Who counts as sender or receiver | The store's side: any store manager for the company store, any member for a project store | Deliveries are between stores. The person who sent one may not be the one who sees it arrive back. |
| Quantities | Exact decimals, up to three places | Concrete comes in 2.5 m³; floating point would let stock drift. |
| "Last delivery" in a project store | The last delivery of that material recorded into the store or sent out of it | It is when material last physically moved. |
| Paging | Offset plus total everywhere, except the company-wide delivery list, which pages by cursor with no total | Per-project lists are small. Offsets and totals over 400,000 deliveries would rescan the table on every page. |
| `PRJ-9999` and beyond | `PRJ-10000` | IDs stay unique and ordered; the brief's four digits are the minimum width. |
| Postgres version, driver | Postgres 18; `package:postgres` pinned to 3.5.20 | 3.6.0 came out days before this was written and changes how pooled connections are reset. |

## Trade-offs I accepted

- **A database round trip on every request** for the session and role (one primary-key lookup, well under a
  millisecond). That is the price of instant logout and of role changes that apply on the next request.
- **One writer per project at a time.** Task, dependency and member changes take the project row lock. That makes
  the numbering, cycle and admin rules simple to get right, and human-paced edits never notice. An automated
  bulk import into one project would queue.
- **Blocked is recomputed for the whole project on every task write.** It costs a few milliseconds at 3,000 tasks
  and cannot drift. A 100,000-task project would need incremental updates instead.
- **Task details for the largest projects take about 100 ms.** The brief asks for everything upstream and
  downstream, which can be 2,500 tasks. The time goes into building that response, not into finding it.
- **Removed projects and materials stay as rows**, so every read filters on `deleted_at`. In return, numbers are
  never reused and delivery history stays whole.
- **The login lockout lives in memory**, so it resets on restart and would not be shared across several API
  processes. That is fine for one small server; more processes would need it in Postgres or Redis.
- **CORS allows any origin.** Tokens travel in the `Authorization` header, not in cookies, so this exposes no one
  to cross-site request forgery. A deployment would still list its frontend's origin.
- **The seeder switches off per-row foreign-key triggers for its own session** (which needs the superuser that
  the compose setup has), then checks every reference in bulk. Checking six million references one row at a
  time would take minutes.
- **No email verification and no password reset.** Both are outside the brief, and both need an email service.

## What I would change or add with more time

- **Lock down role selection** as described [above](#first-one-decision-you-should-know-about).
- **Detect refresh-token reuse.** If an old refresh token is replayed, revoke the whole session, with a short
  grace window so two browser tabs refreshing at once do not log the user out.
- **An audit trail:** who changed a task's status, who added or removed whom, who moved what stock.
- **More notification types** beyond invitations (a delivery waiting to be recorded, a task becoming unblocked),
  and pushing the unread count over server-sent events instead of having the frontend poll it.
- **Optimistic concurrency for edits** (an `ETag` or version per project, task and material), so two people
  editing the same task cannot silently overwrite each other.
- **Concurrent load testing** (k6 or similar) on hardware the size of the target server. The numbers above are
  single-client latencies on a larger machine.
- **Cheaper task details for huge graphs:** build the related-task JSON in Postgres, or page the upstream and
  downstream lists.
- **Operations:** structured logs, request metrics, tracing, and the slow-query log in front of someone.
- **Contract tests generated from the OpenAPI file**, so docs and behaviour cannot drift apart.
- **A sessions screen** to see and end other devices' sessions.
- **Controlled lists for units and categories**, instead of free text.

## Code layout

```
bin/server.dart            wait for Postgres, migrate, serve (and `server healthcheck` for Docker)
bin/seed.dart              the scale loader
lib/src/app.dart           every route, in one place
lib/src/auth/              accounts, sessions, tokens, passwords, login lockout
lib/src/projects/          the project access gate, projects, members and invitations
lib/src/notifications/     invitations as the invitee sees them
lib/src/tasks/             tasks, dependencies, status actions, the graph walk for task details
lib/src/stock/             materials, the company store, project stores, deliveries
lib/src/seed/              the seed plan and the SQL that generates the data
lib/src/http/              validation, JSON, errors, paging, middleware, the docs page
migrations/                the schema, as SQL with the reasoning next to each table
docs/openapi.yaml          the API description served at /docs
test/                      integration tests (one database per file)
tool/bench.dart            the screen benchmark
```
