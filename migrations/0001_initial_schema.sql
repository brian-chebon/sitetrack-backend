-- SiteTrack data model.
--
-- Conventions
--   * Enumerations are text columns with a CHECK constraint. They read clearly
--     in psql and in query results, and adding a value is a one-line migration.
--   * Display IDs (PRJ-0042, PRJ-0042-T-0137) are never stored. They are
--     derived from integer keys by project_code() and task_code(), so they
--     cannot drift from the keys and cost no storage on 500,000 tasks.
--   * Values that screens sort, filter or count on and that would otherwise
--     need a scan of a large table (task counts per project, the Blocked flag,
--     company stock in transit) are kept current by the same transaction that
--     changes their inputs.
--   * Quantities are numeric(14,3): exact decimals (2.5 m3 of concrete), so
--     stock never drifts through floating-point rounding.
--   * Every table that people change has created_at / updated_at, set by the
--     API in the same statement that makes the change.


-- ---------------------------------------------------------------------------
-- Display IDs
-- ---------------------------------------------------------------------------

-- PRJ- and at least four digits. lpad() alone would cut 10000 down to '1000',
-- so numbers past 9999 grow to five digits instead of colliding.
CREATE FUNCTION project_code(project_id integer) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN 'PRJ-' || lpad(project_id::text, greatest(4, length(project_id::text)), '0');

-- PRJ-0042-T-0137: the project's code, then the task's number in the project.
CREATE FUNCTION task_code(project_id integer, task_number integer) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN project_code(project_id) || '-T-'
       || lpad(task_number::text, greatest(4, length(task_number::text)), '0');

-- Company-wide counters. 'project' holds the last project number handed out.
-- Taking the next number is `UPDATE counters ... RETURNING value` inside the
-- transaction that inserts the project: the row lock makes concurrent creates
-- queue for a moment and get distinct numbers, a rolled-back create releases
-- its number, and nothing ever decrements it, so numbers are never reused.
-- (A sequence would also be unique but leaves gaps on every rollback.)
CREATE TABLE counters (
  name  text PRIMARY KEY,
  value integer NOT NULL CHECK (value >= 0)
);
INSERT INTO counters (name, value) VALUES ('project', 0);


-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

CREATE TABLE users (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200),
  -- Stored trimmed and lower-cased, so the unique index is case-insensitive.
  email         text NOT NULL CHECK (email = lower(btrim(email)) AND char_length(email) <= 320),
  -- bcrypt; the plain password is never stored or returned.
  password_hash text NOT NULL,
  app_role      text NOT NULL CHECK (app_role IN ('user', 'store_manager', 'super_admin')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_key ON users (email);

-- One row per login. The access JWT carries the session id, and every request
-- checks that its session is still live, so logging out (revoked_at) ends that
-- session on its next request, while other devices stay signed in. Role and
-- project membership are read from the database on every request too, never
-- from the token, so changes to them apply immediately.
CREATE TABLE sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  -- SHA-256 of the current refresh token. Each refresh replaces the token, so
  -- a stolen, already-used refresh token is worthless.
  refresh_token_hash bytea NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_used_at       timestamptz NOT NULL DEFAULT now(),
  -- Pushed forward on every refresh: an active user stays signed in, an idle
  -- session lapses.
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz
);
CREATE INDEX sessions_user_id_idx ON sessions (user_id);


-- ---------------------------------------------------------------------------
-- Projects, members and invitations
-- ---------------------------------------------------------------------------

CREATE TABLE projects (
  -- The project number from counters; shown as project_code(id).
  id                integer PRIMARY KEY CHECK (id > 0),
  name              text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200),
  planned_start     date NOT NULL,
  planned_end       date NOT NULL,
  created_by        bigint NOT NULL REFERENCES users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  -- Removed projects keep their row so their number is never reused and the
  -- company store's delivery history still has a project to point at. Every
  -- read filters on deleted_at IS NULL.
  deleted_at        timestamptz,

  -- Last task number handed out in this project. Bumped with
  -- `UPDATE ... RETURNING` under the project row lock; never decremented.
  last_task_number  integer NOT NULL DEFAULT 0 CHECK (last_task_number >= 0),

  -- Kept current by refresh_project_member_count() and
  -- refresh_project_task_stats() (below), so the projects screen can sort
  -- 2,000 projects by percentage done without reading 500,000 tasks.
  member_count      integer NOT NULL DEFAULT 0 CHECK (member_count >= 0),
  tasks_not_started integer NOT NULL DEFAULT 0 CHECK (tasks_not_started >= 0),
  tasks_in_progress integer NOT NULL DEFAULT 0 CHECK (tasks_in_progress >= 0),
  tasks_done        integer NOT NULL DEFAULT 0 CHECK (tasks_done >= 0),
  tasks_blocked     integer NOT NULL DEFAULT 0 CHECK (tasks_blocked >= 0),

  CHECK (planned_end >= planned_start)
);

CREATE TABLE project_members (
  project_id integer NOT NULL REFERENCES projects (id),
  user_id    bigint  NOT NULL REFERENCES users (id),
  is_admin   boolean NOT NULL DEFAULT false,
  joined_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, user_id)
);
-- "Which projects can I see, and am I admin there?" without touching the table.
CREATE INDEX project_members_user_idx ON project_members (user_id, project_id) INCLUDE (is_admin);

CREATE TABLE project_invitations (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id  integer NOT NULL REFERENCES projects (id),
  invitee_id  bigint  NOT NULL REFERENCES users (id),
  invited_by  bigint  NOT NULL REFERENCES users (id),
  status      text NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'accepted', 'rejected', 'withdrawn')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  -- When and by whom it stopped being pending: the invitee for accepted or
  -- rejected, a project admin for withdrawn.
  closed_at   timestamptz,
  closed_by   bigint REFERENCES users (id),
  -- When the invitee saw it; drives the unread count in the header.
  read_at     timestamptz,
  CHECK ((status = 'pending') = (closed_at IS NULL)),
  CHECK ((closed_at IS NULL) = (closed_by IS NULL))
);
-- At most one open invitation per person per project.
CREATE UNIQUE INDEX project_invitations_pending_key
  ON project_invitations (project_id, invitee_id) WHERE status = 'pending';
-- The notifications screen: one person's invitations, newest first.
CREATE INDEX project_invitations_invitee_idx
  ON project_invitations (invitee_id, created_at DESC, id DESC);

-- Recounts a project's members. Called by every transaction that adds or
-- removes a member, while it holds the project row lock.
CREATE FUNCTION refresh_project_member_count(p_project_id integer) RETURNS void
LANGUAGE sql
BEGIN ATOMIC
  UPDATE projects p
     SET member_count = (SELECT count(*) FROM project_members m WHERE m.project_id = p_project_id)
   WHERE p.id = p_project_id;
END;


-- ---------------------------------------------------------------------------
-- Tasks and dependencies
-- ---------------------------------------------------------------------------

CREATE TABLE tasks (
  project_id    integer NOT NULL REFERENCES projects (id),
  -- Counts up within the project; shown as task_code(project_id, number).
  number        integer NOT NULL CHECK (number > 0),
  name          text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200),
  planned_start date NOT NULL,
  planned_end   date NOT NULL,
  -- Changed only by the Start, Mark as done and Reopen actions.
  status        text NOT NULL DEFAULT 'not_started'
                CHECK (status IN ('not_started', 'in_progress', 'done')),
  -- Derived, never set by a person: not done, and some task it waits on,
  -- directly or through other tasks, is not done. Kept current by
  -- refresh_project_task_stats(). Late is not stored: it depends on today's
  -- date, so it is computed when read (task_is_late()).
  blocked       boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, number),
  CHECK (planned_end >= planned_start)
);
-- Late tasks per project. Because planned_start <= planned_end, a task that
-- has not started is late exactly when its start date has passed, and a task
-- in progress is late exactly when its end date has passed. These two small
-- partial indexes answer "late tasks per project" for every project at once.
CREATE INDEX tasks_not_started_start_idx ON tasks (project_id, planned_start) WHERE status = 'not_started';
CREATE INDEX tasks_in_progress_end_idx   ON tasks (project_id, planned_end)   WHERE status = 'in_progress';

-- "task_number depends on depends_on_number": the first waits for the second.
-- Both ends carry the same project_id, so the composite foreign keys make a
-- dependency across projects impossible to store, not just rejected by code.
CREATE TABLE task_dependencies (
  project_id        integer NOT NULL,
  task_number       integer NOT NULL,
  depends_on_number integer NOT NULL,
  PRIMARY KEY (project_id, task_number, depends_on_number),
  FOREIGN KEY (project_id, task_number)       REFERENCES tasks (project_id, number) ON DELETE CASCADE,
  FOREIGN KEY (project_id, depends_on_number) REFERENCES tasks (project_id, number) ON DELETE CASCADE,
  CHECK (task_number <> depends_on_number)
);
-- The other direction: which tasks wait on this one.
CREATE INDEX task_dependencies_dependents_idx
  ON task_dependencies (project_id, depends_on_number, task_number);

-- Late, as the brief defines it: not done and the planned end has passed, or
-- not started and the planned start has passed. `today` is passed in so the
-- whole request uses one date.
CREATE FUNCTION task_is_late(status text, planned_start date, planned_end date, today date)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN status <> 'done'
       AND (planned_end < today OR (status = 'not_started' AND planned_start < today));

-- Recomputes Blocked for every task in one project, then the project's task
-- counters. Called at the end of every transaction that adds, removes or
-- changes the status of a task or a dependency in the project, while that
-- transaction holds the project row lock (so two changes cannot interleave).
--
-- A project has at most a few thousand tasks, so recomputing the whole project
-- costs a few milliseconds and, unlike patching counters by +1/-1, cannot drift.
CREATE FUNCTION refresh_project_task_stats(p_project_id integer) RETURNS void
LANGUAGE sql
BEGIN ATOMIC
  -- waiting = every task downstream of an unfinished task: the direct
  -- dependents of unfinished tasks, then their dependents, and so on. UNION
  -- drops rows already found, so each task is visited once and the walk is
  -- linear in the number of dependencies.
  WITH RECURSIVE waiting (task_number) AS (
      SELECT d.task_number
        FROM task_dependencies d
        JOIN tasks upstream
          ON upstream.project_id = d.project_id
         AND upstream.number = d.depends_on_number
       WHERE d.project_id = p_project_id
         AND upstream.status <> 'done'
    UNION
      SELECT d.task_number
        FROM waiting w
        JOIN task_dependencies d
          ON d.project_id = p_project_id
         AND d.depends_on_number = w.task_number
  ),
  computed AS (
    SELECT t.number, (t.status <> 'done' AND w.task_number IS NOT NULL) AS blocked
      FROM tasks t
      LEFT JOIN waiting w ON w.task_number = t.number
     WHERE t.project_id = p_project_id
  )
  UPDATE tasks t
     SET blocked = c.blocked
    FROM computed c
   WHERE t.project_id = p_project_id
     AND t.number = c.number
     AND t.blocked <> c.blocked;

  UPDATE projects p
     SET (tasks_not_started, tasks_in_progress, tasks_done, tasks_blocked) = (
           SELECT count(*) FILTER (WHERE t.status = 'not_started'),
                  count(*) FILTER (WHERE t.status = 'in_progress'),
                  count(*) FILTER (WHERE t.status = 'done'),
                  count(*) FILTER (WHERE t.blocked)
             FROM tasks t
            WHERE t.project_id = p_project_id)
   WHERE p.id = p_project_id;
END;


-- ---------------------------------------------------------------------------
-- Materials and stores
-- ---------------------------------------------------------------------------
-- There is no stores table. The company store is a singleton, so it is the
-- company_stock table; each project has exactly one store, so a project store
-- is identified by its project. A delivery always runs between the company
-- store and one project store, which is why deliveries carry a project_id and
-- a direction rather than two store IDs: a delivery between two project
-- stores cannot be expressed.

CREATE TABLE materials (
  id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name       text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200),
  category   text NOT NULL CHECK (char_length(btrim(category)) BETWEEN 1 AND 100),
  unit       text NOT NULL CHECK (char_length(btrim(unit)) BETWEEN 1 AND 30),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- Removing a material hides it from the catalogue and from new deliveries;
  -- past deliveries still show it.
  deleted_at timestamptz
);
CREATE UNIQUE INDEX materials_name_key ON materials (lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX materials_category_idx ON materials (category) WHERE deleted_at IS NULL;

-- The company store: exactly one row per material, inserted with the material.
CREATE TABLE company_stock (
  material_id   integer PRIMARY KEY REFERENCES materials (id),
  -- On the shelf now. Never negative, even under concurrent deliveries: every
  -- decrement is `SET quantity = quantity - x WHERE quantity >= x`, and this
  -- CHECK is the backstop.
  quantity      numeric(14,3) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  -- Sent to project stores and not yet recorded, rejected or cancelled.
  in_transit    numeric(14,3) NOT NULL DEFAULT 0 CHECK (in_transit >= 0),
  reorder_point numeric(14,3) NOT NULL DEFAULT 0 CHECK (reorder_point >= 0),
  -- Out of stock at 0; Low stock above 0 and at or below the reorder point;
  -- Available above it. Stored so the stock screen can filter on it.
  status        text GENERATED ALWAYS AS (
                  CASE WHEN quantity = 0 THEN 'out_of_stock'
                       WHEN quantity <= reorder_point THEN 'low_stock'
                       ELSE 'available'
                  END) STORED,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX company_stock_status_idx ON company_stock (status);

-- Every time a store manager adds stock from a supplier: the only way new
-- material enters SiteTrack, kept as an audit trail.
CREATE TABLE stock_additions (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  material_id integer NOT NULL REFERENCES materials (id),
  quantity    numeric(14,3) NOT NULL CHECK (quantity > 0),
  added_by    bigint NOT NULL REFERENCES users (id),
  added_at    timestamptz NOT NULL DEFAULT now(),
  note        text CHECK (char_length(note) <= 1000)
);
CREATE INDEX stock_additions_material_idx ON stock_additions (material_id, added_at DESC);

-- A project store: one row per material that has ever been delivered there.
CREATE TABLE project_stock (
  project_id       integer NOT NULL REFERENCES projects (id),
  material_id      integer NOT NULL REFERENCES materials (id),
  quantity         numeric(14,3) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  -- The last delivery of this material into the store (recorded) or out of
  -- it (sent), for the store screen's "last delivery" column and sort.
  last_delivery_at timestamptz NOT NULL,
  PRIMARY KEY (project_id, material_id)
);


-- ---------------------------------------------------------------------------
-- Deliveries
-- ---------------------------------------------------------------------------

CREATE TABLE deliveries (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id integer NOT NULL REFERENCES projects (id),
  -- to_project: company store -> project store.
  -- to_company: project store -> company store.
  direction  text NOT NULL CHECK (direction IN ('to_project', 'to_company')),
  -- Starts in_transit and changes exactly once, with
  -- `UPDATE ... WHERE status = 'in_transit'`, so a record racing a cancel has
  -- exactly one winner. Lines are never edited after the delivery is sent.
  status     text NOT NULL DEFAULT 'in_transit'
             CHECK (status IN ('in_transit', 'delivered', 'rejected', 'cancelled')),
  sent_by    bigint NOT NULL REFERENCES users (id),
  sent_at    timestamptz NOT NULL DEFAULT now(),
  -- Who ended the transit and when: the receiver for delivered or rejected,
  -- the sender for cancelled.
  closed_by  bigint REFERENCES users (id),
  closed_at  timestamptz,
  note       text CHECK (char_length(note) <= 1000),
  CHECK ((status = 'in_transit') = (closed_at IS NULL)),
  CHECK ((closed_at IS NULL) = (closed_by IS NULL))
);
-- A project's deliveries, newest first.
CREATE INDEX deliveries_project_idx ON deliveries (project_id, sent_at DESC, id DESC);
-- The company store's deliveries across all projects, newest first.
CREATE INDEX deliveries_sent_idx ON deliveries (sent_at DESC, id DESC);
-- Open deliveries, a small fraction of the 400,000.
CREATE INDEX deliveries_in_transit_idx ON deliveries (project_id) WHERE status = 'in_transit';

CREATE TABLE delivery_lines (
  delivery_id bigint  NOT NULL REFERENCES deliveries (id),
  material_id integer NOT NULL REFERENCES materials (id),
  quantity    numeric(14,3) NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (delivery_id, material_id)
);
