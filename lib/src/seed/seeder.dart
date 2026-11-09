import 'package:postgres/postgres.dart';

import 'seed_plan.dart';

/// Fills an empty database with a large company history that obeys every
/// rule the API enforces, so the API can be judged against it:
///
///   * Tasks only depend on lower-numbered tasks of their own project, so the
///     graph has no cycles. Statuses follow each project's progress through
///     its dates, so a started task never waits on an unfinished one, and
///     projects running behind schedule produce Late tasks naturally. Blocked
///     and the per-project counters are then computed by the same
///     refresh_project_task_stats() the API uses.
///   * Deliveries go out from the company store to project stores while each
///     project is active; returns mirror earlier received deliveries at no
///     more than 30% of each line. Every store's stock is derived from that
///     history, and supplier stock additions are back-filled to match, so the
///     numbers add up and nothing is ever negative.
///   * Everything is generated in SQL (generate_series), not row by row.
class Seeder {
  Seeder(this._connection, this._plan, {void Function(String)? log})
    : _log = log ?? print;

  final Connection _connection;
  final SeedPlan _plan;
  final void Function(String) _log;

  /// Seeds; [passwordHash] is the bcrypt hash every seeded account shares.
  Future<void> run(String passwordHash) async {
    final p = _plan;
    final total = Stopwatch()..start();
    _log('Seeding: $p');

    _checkedPerRow = !await _skipPerRowChecks();

    await _step('Session settings', '''
      SET synchronous_commit = off;
      SET work_mem = '256MB';
      SET maintenance_work_mem = '512MB';
      SELECT setseed(0.2026);''');

    await _step('Users', '''
      INSERT INTO users (id, name, email, password_hash, app_role, created_at, updated_at)
      OVERRIDING SYSTEM VALUE
      SELECT i,
             CASE i WHEN 1 THEN 'Sara Al-Busaidi' WHEN 2 THEN 'Musa Kariuki' WHEN 3 THEN 'Uma Achieng'
                    ELSE n.first[1 + i % 40] || ' ' || n.last[1 + (i / 40) % 40] END,
             CASE i WHEN 1 THEN 'superadmin@sitetrack.test'
                    WHEN 2 THEN 'manager@sitetrack.test'
                    WHEN 3 THEN 'user@sitetrack.test'
                    ELSE lower(n.first[1 + i % 40] || '.' || n.last[1 + (i / 40) % 40]) || i || '@sitetrack.test' END,
             '$passwordHash',
             CASE WHEN i = 1 OR i % 200 = 0 THEN 'super_admin'
                  WHEN i = 2 OR i % 50 = 0 THEN 'store_manager'
                  ELSE 'user' END,
             t.at, t.at
        FROM generate_series(1, ${p.users}) i
       CROSS JOIN (SELECT ARRAY['Amina','Brian','Chebet','David','Esther','Faisal','Grace','Hassan',
                                'Imani','James','Kamau','Leila','Mohammed','Njeri','Omar','Purity',
                                'Qasim','Rehema','Said','Tabitha','Umar','Wanjiru','Yusuf','Zawadi',
                                'Aisha','Kevin','Fatma','Otieno','Mariam','Salim','Halima','Peter',
                                'Noor','Joseph','Zainab','Daniel','Khadija','Samuel','Mercy','Ali'] AS first,
                          ARRAY['Achieng','Al-Balushi','Mwangi','Al-Harthy','Otieno','Al-Rawahi','Kariuki',
                                'Al-Hinai','Wambui','Al-Farsi','Odhiambo','Al-Said','Njoroge','Al-Kindi',
                                'Kiptoo','Al-Busaidi','Mutua','Al-Lawati','Chebet','Al-Maskari','Kamau',
                                'Al-Riyami','Wekesa','Al-Shukaili','Ochieng','Al-Zadjali','Kibet',
                                'Al-Mahrouqi','Njeri','Al-Siyabi','Barasa','Al-Abri','Korir','Al-Habsi',
                                'Omondi','Al-Amri','Mbugua','Al-Ghafri','Rotich','Al-Jabri'] AS last) n
       CROSS JOIN LATERAL (SELECT now() - interval '6 years'
                                  + (i::float / ${p.users}) * interval '6 years' AS at) t;
      ANALYZE users;''');

    await _step('Materials', '''
      CREATE TEMP TABLE seed_products (k serial PRIMARY KEY, category text, name text, unit text);
      INSERT INTO seed_products (category, name, unit) VALUES
        ('Cement & Concrete', 'Cement OPC 42.5N 50 kg', 'bag'),
        ('Cement & Concrete', 'Cement PPC 32.5R 50 kg', 'bag'),
        ('Cement & Concrete', 'Ready-mix concrete C25/30', 'm3'),
        ('Cement & Concrete', 'Ready-mix concrete C30/37', 'm3'),
        ('Cement & Concrete', 'Lean concrete C15', 'm3'),
        ('Cement & Concrete', 'Concrete plasticiser', 'litre'),
        ('Aggregates', 'River sand', 'tonne'),
        ('Aggregates', 'Crushed stone 20 mm', 'tonne'),
        ('Aggregates', 'Ballast 40 mm', 'tonne'),
        ('Aggregates', 'Quarry dust', 'tonne'),
        ('Aggregates', 'Gabion stone', 'tonne'),
        ('Steel & Rebar', 'Rebar Y10 12 m', 'piece'),
        ('Steel & Rebar', 'Rebar Y12 12 m', 'piece'),
        ('Steel & Rebar', 'Rebar Y16 12 m', 'piece'),
        ('Steel & Rebar', 'Rebar Y20 12 m', 'piece'),
        ('Steel & Rebar', 'BRC mesh A142', 'sheet'),
        ('Steel & Rebar', 'Binding wire 1.6 mm 25 kg', 'roll'),
        ('Steel & Rebar', 'Steel I-beam 203x133', 'piece'),
        ('Steel & Rebar', 'Hollow section 50x50x3', 'piece'),
        ('Timber & Formwork', 'Timber 2x4 4.8 m', 'piece'),
        ('Timber & Formwork', 'Timber 3x2 4.8 m', 'piece'),
        ('Timber & Formwork', 'Marine plywood 18 mm', 'sheet'),
        ('Timber & Formwork', 'Formwork panel 1.2x0.6 m', 'piece'),
        ('Timber & Formwork', 'Scaffold board 3.9 m', 'piece'),
        ('Bricks & Blocks', 'Concrete block 6 inch', 'piece'),
        ('Bricks & Blocks', 'Concrete block 8 inch', 'piece'),
        ('Bricks & Blocks', 'Clay brick', 'piece'),
        ('Bricks & Blocks', 'Machine-cut stone 9x9', 'piece'),
        ('Bricks & Blocks', 'Interlocking paver 80 mm', 'm2'),
        ('Roofing', 'Box profile sheet 0.5 mm', 'sheet'),
        ('Roofing', 'Clay roof tile', 'piece'),
        ('Roofing', 'Ridge cap', 'piece'),
        ('Roofing', 'Roofing felt', 'roll'),
        ('Roofing', 'Gutter 150 mm 6 m', 'piece'),
        ('Plumbing', 'uPVC pipe 110 mm 6 m', 'piece'),
        ('Plumbing', 'PPR pipe 25 mm 4 m', 'piece'),
        ('Plumbing', 'Gate valve 25 mm', 'piece'),
        ('Plumbing', 'Water tank 5000 l', 'piece'),
        ('Plumbing', 'Floor trap 100 mm', 'piece'),
        ('Electrical', 'Cable 2.5 mm2 twin and earth 100 m', 'roll'),
        ('Electrical', 'Cable 4 mm2 100 m', 'roll'),
        ('Electrical', 'Conduit 20 mm 3 m', 'piece'),
        ('Electrical', 'Distribution board 12-way', 'piece'),
        ('Electrical', 'Socket outlet 13 A', 'piece'),
        ('Electrical', 'LED panel 600x600', 'piece'),
        ('Paint & Coatings', 'Emulsion paint 20 l', 'bucket'),
        ('Paint & Coatings', 'Gloss enamel 4 l', 'tin'),
        ('Paint & Coatings', 'Primer sealer 20 l', 'bucket'),
        ('Paint & Coatings', 'Anti-rust paint 4 l', 'tin'),
        ('Fixings', 'Anchor bolt M12', 'box'),
        ('Fixings', 'Wood screws 4x40', 'box'),
        ('Fixings', 'Roofing nails 3 inch 25 kg', 'carton'),
        ('Fixings', 'Chemical anchor 300 ml', 'cartridge'),
        ('Waterproofing & Insulation', 'Bitumen membrane 4 mm', 'roll'),
        ('Waterproofing & Insulation', 'Waterproof slurry 20 kg', 'bag'),
        ('Waterproofing & Insulation', 'Rock wool slab 50 mm', 'pack'),
        ('Waterproofing & Insulation', 'DPM polythene 1000 gauge', 'roll'),
        ('Glass & Glazing', 'Clear float glass 6 mm', 'm2'),
        ('Glass & Glazing', 'Tempered glass 10 mm', 'm2'),
        ('Glass & Glazing', 'Aluminium window frame', 'piece'),
        ('Tiles & Flooring', 'Ceramic floor tile 60x60', 'm2'),
        ('Tiles & Flooring', 'Porcelain tile 60x120', 'm2'),
        ('Tiles & Flooring', 'Tile adhesive 20 kg', 'bag'),
        ('Tiles & Flooring', 'Tile grout 5 kg', 'bag'),
        ('Plaster & Drywall', 'Gypsum board 12.5 mm', 'sheet'),
        ('Plaster & Drywall', 'Plaster of Paris 25 kg', 'bag'),
        ('Plaster & Drywall', 'Skim coat 20 kg', 'bag'),
        ('Plaster & Drywall', 'Metal stud 3 m', 'piece'),
        ('Safety Equipment', 'Safety helmet', 'piece'),
        ('Safety Equipment', 'Hi-vis vest', 'piece'),
        ('Safety Equipment', 'Safety harness', 'piece'),
        ('Safety Equipment', 'Safety boots', 'pair'),
        ('Drainage', 'Manhole cover 600x600', 'piece'),
        ('Drainage', 'Concrete pipe 450 mm', 'piece'),
        ('Drainage', 'Kerb stone', 'piece');

      INSERT INTO materials (id, name, category, unit, created_at, updated_at)
      OVERRIDING SYSTEM VALUE
      SELECT i,
             pr.name || ', ' || b.brands[1 + ((i - 1) / c.n) % cardinality(b.brands)]
                     || ' SKU-' || lpad(i::text, 5, '0'),
             pr.category, pr.unit, t.at, t.at
        -- random() in the select list, so each material gets its own date
        FROM (SELECT i, now() - interval '6 years' + random() * interval '5 years' AS at
                FROM generate_series(1, ${p.materials}) i) t
       CROSS JOIN (SELECT count(*)::int AS n FROM seed_products) c
       CROSS JOIN (SELECT ARRAY['Bamburi','Simba','Raysut','Oman Cement','Mabati','Devki','Jindal',
                                'Galfar','Crown','Basco','Kansai','Sika','Fosroc','Saint-Gobain',
                                'Kenbro','Al Hassan'] AS brands) b
        JOIN seed_products pr ON pr.k = 1 + (i - 1) % c.n;
      ANALYZE materials;''');

    await _step('Projects', '''
      INSERT INTO projects (id, name, planned_start, planned_end, created_by, created_at, updated_at)
      SELECT pid,
             n.places[1 + pid % cardinality(n.places)] || ' '
               || n.kinds[1 + (pid / cardinality(n.places)) % cardinality(n.kinds)]
               || ' Phase ' || (1 + pid % 4),
             s.start, s.start + s.duration, c.creator, c.created, c.created
        FROM generate_series(1, ${p.projects}) pid
       CROSS JOIN (SELECT ARRAY['Muscat','Sohar','Nizwa','Salalah','Sur','Duqm','Ibri','Barka',
                                'Nairobi','Mombasa','Kisumu','Nakuru','Eldoret','Thika','Malindi',
                                'Naivasha','Seeb','Rustaq','Bahla','Khasab','Machakos','Nyeri',
                                'Kericho','Garissa'] AS places,
                          ARRAY['Tower','Bridge','Mall','Hospital Wing','Primary School','Warehouse',
                                'Residences','Office Park','Road Upgrade','Water Treatment Plant',
                                'Hotel','Stadium Stand','Logistics Hub','Clinic','Apartments',
                                'Business Centre'] AS kinds) n
       -- Older projects have lower numbers: starts run from five years ago
       -- to six months ahead, as IDs count up over the years.
       CROSS JOIN LATERAL (SELECT (current_date - 1825 + ((pid - 1) * 2010 / ${p.projects})
                                   + (pid * 13) % 30)::date AS start,
                                  120 + (pid * 37) % 600 AS duration) s
       CROSS JOIN LATERAL (SELECT CASE WHEN pid % 100 = 0 THEN 3
                                       ELSE 4 + (pid * 7) % (${p.users} - 3) END AS creator,
                                  least(s.start - 30, current_date - 1)::timestamptz AS created) c;
      UPDATE counters SET value = ${p.projects} WHERE name = 'project';
      ANALYZE projects;''');

    await _step('Members', '''
      INSERT INTO project_members (project_id, user_id, is_admin, joined_at)
      SELECT id, created_by, true, created_at FROM projects;

      -- Others at random, leaving out the demo user (ID 3), whose projects
      -- are set below so the README can say exactly which they are.
      INSERT INTO project_members (project_id, user_id, is_admin, joined_at)
      SELECT pr.id, u.id, j <= 2, pr.created_at + j * interval '2 days'
        FROM projects pr
       CROSS JOIN LATERAL generate_series(1, 2 + (pr.id * 13) % ${p.maxExtraMembers}) j
       CROSS JOIN LATERAL (SELECT 1 + ((pr.id * 7 + j * 1543) % ${p.users}) AS id) u
       WHERE u.id <> 3
      ON CONFLICT DO NOTHING;

      -- The demo user is in every 50th project and admin of every 100th.
      INSERT INTO project_members (project_id, user_id, is_admin, joined_at)
      SELECT id, 3, id % 100 = 0, created_at + interval '1 day' FROM projects WHERE id % 50 = 0
      ON CONFLICT (project_id, user_id) DO UPDATE
         SET is_admin = project_members.is_admin OR excluded.is_admin;

      UPDATE projects pr SET member_count = c.n
        FROM (SELECT project_id, count(*)::int AS n FROM project_members GROUP BY project_id) c
       WHERE c.project_id = pr.id;
      ANALYZE project_members;''');

    await _step(
      'Invitations',
      '''
      -- Most members joined by accepting an invitation.
      INSERT INTO project_invitations
        (project_id, invitee_id, invited_by, status, created_at, closed_at, closed_by, read_at)
      SELECT m.project_id, m.user_id, m.created_by, 'accepted',
             m.joined_at - interval '2 days', m.joined_at, m.user_id, m.joined_at - interval '1 day'
        FROM (SELECT m.*, pr.created_by,
                     row_number() OVER (PARTITION BY m.project_id ORDER BY m.joined_at, m.user_id) AS rn
                FROM project_members m
                JOIN projects pr ON pr.id = m.project_id
               WHERE m.user_id <> pr.created_by) m
       WHERE m.rn <= 10;

      -- The rest went to people who are not members: some still open, some
      -- rejected, some withdrawn. Each project ends with the same total.
      WITH accepted AS (
        SELECT project_id, count(*) AS n FROM project_invitations GROUP BY project_id
      ),
      candidates AS (
        SELECT pr.id AS project_id, pr.created_by, pr.created_at, u.invitee_id,
               row_number() OVER (PARTITION BY pr.id ORDER BY u.j) AS rn,
               coalesce(a.n, 0) AS accepted
          FROM projects pr
          LEFT JOIN accepted a ON a.project_id = pr.id
         CROSS JOIN LATERAL generate_series(1, 80) j
         CROSS JOIN LATERAL (SELECT 1 + ((pr.id * 31 + j * 2111) % ${p.users}) AS invitee_id, j) u
         WHERE NOT EXISTS (SELECT 1 FROM project_members m
                            WHERE m.project_id = pr.id AND m.user_id = u.invitee_id)
      ),
      chosen AS (
        SELECT c.*,
               CASE c.rn % 6 WHEN 0 THEN 'withdrawn' WHEN 1 THEN 'rejected' WHEN 2 THEN 'rejected'
                             ELSE 'pending' END AS status,
               least(now() - interval '1 hour',
                     c.created_at + random() * greatest(now() - c.created_at, interval '1 hour')) AS sent
          FROM candidates c
         WHERE c.rn <= ${p.invitationsPerProject} - c.accepted
      )
      INSERT INTO project_invitations
        (project_id, invitee_id, invited_by, status, created_at, closed_at, closed_by, read_at)
      SELECT project_id, invitee_id, created_by, status, sent,
             CASE WHEN status <> 'pending' THEN least(now(), sent + (1 + random() * 9) * interval '1 day') END,
             CASE status WHEN 'rejected' THEN invitee_id WHEN 'withdrawn' THEN created_by END,
             CASE WHEN status <> 'pending' OR rn % 2 = 0 THEN sent + interval '1 hour' END
        FROM chosen;

      -- A few open invitations for the demo user's notifications screen.
      INSERT INTO project_invitations (project_id, invitee_id, invited_by, status, created_at)
      SELECT pr.id, 3, pr.created_by, 'pending', now() - (pr.id % 10) * interval '1 day'
        FROM projects pr
       WHERE pr.id % 50 = 25
         AND NOT EXISTS (SELECT 1 FROM project_members m WHERE m.project_id = pr.id AND m.user_id = 3)
         AND NOT EXISTS (SELECT 1 FROM project_invitations i
                          WHERE i.project_id = pr.id AND i.invitee_id = 3 AND i.status = 'pending');''',
    );

    final bigEvery = p.projects ~/ p.bigProjects;
    final averageTasks =
        (p.tasks - p.bigProjects * p.bigProjectTasks) /
        (p.projects - p.bigProjects);
    await _step('Tasks', '''
      CREATE TEMP TABLE seed_task_sizes AS
      SELECT id, (id % $bigEvery = 0 AND id / $bigEvery <= ${p.bigProjects}) AS big, 0 AS size
        FROM projects;
      UPDATE seed_task_sizes
         SET size = CASE WHEN big THEN ${p.bigProjectTasks}
                         ELSE greatest(1, round($averageTasks
                                                * (0.15 + 1.7 * ((id * 7919) % 1000) / 1000.0)))::int
                    END;
      -- Make up any rounding shortfall so the total reaches the target.
      WITH d AS (SELECT ${p.tasks} - sum(size) AS deficit, count(*) FILTER (WHERE NOT big) AS n
                   FROM seed_task_sizes),
           r AS (SELECT id, row_number() OVER (ORDER BY id) AS rn FROM seed_task_sizes WHERE NOT big)
      UPDATE seed_task_sizes s
         SET size = s.size + (d.deficit / d.n)::int
                    + CASE WHEN r.rn <= d.deficit % d.n THEN 1 ELSE 0 END
        FROM d, r
       WHERE r.id = s.id AND d.deficit > 0;

      -- Planned dates spread through the project in task order.
      INSERT INTO tasks (project_id, number, name, planned_start, planned_end, created_at, updated_at)
      SELECT s.id, k,
             v.verbs[1 + (k * 7 + s.id) % 20] || ' ' || v.objects[1 + (k * 11 + s.id * 3) % 20]
               || ', zone ' || (1 + k % 12),
             d.start, d.start + (2 + (k * 7 + s.id) % 19),
             pr.created_at, pr.created_at
        FROM seed_task_sizes s
        JOIN projects pr ON pr.id = s.id
       CROSS JOIN (SELECT ARRAY['Survey','Excavate','Backfill','Pour','Cure','Erect','Install',
                                'Inspect','Plaster','Paint','Wire','Plumb','Tile','Glaze','Clad',
                                'Waterproof','Commission','Level','Brace','Seal'] AS verbs,
                          ARRAY['foundation','ground slab','level 2 slab','columns','core walls',
                                'east facade','west facade','stairwell','lift shaft','roof deck',
                                'car park ramp','drainage run','retaining wall','basement',
                                'mezzanine','plant room','service riser','parapet','canopy',
                                'perimeter fence'] AS objects) v
       CROSS JOIN LATERAL generate_series(1, s.size) k
       CROSS JOIN LATERAL (SELECT pr.planned_start
                                  + ((k - 1)::bigint * greatest(pr.planned_end - pr.planned_start - 20, 1)
                                     / s.size)::int AS start) d;
      UPDATE projects pr SET last_task_number = s.size FROM seed_task_sizes s WHERE s.id = pr.id;
      ANALYZE tasks;''');

    await _step('Dependencies', '''
      -- Each task waits on two earlier tasks from the 30 before it (every
      -- tenth on three), giving long chains and side-by-side waits, and no
      -- cycles: edges only point to lower numbers.
      WITH picks AS (
        SELECT project_id, number, w,
               floor(random() * w)::int AS a,
               1 + floor(random() * greatest(w - 1, 1))::int AS b,
               1 + floor(random() * greatest(w - 1, 1))::int AS c
          FROM (SELECT project_id, number, least(number - 1, 30) AS w
                  FROM tasks WHERE number > 1) t
      )
      INSERT INTO task_dependencies (project_id, task_number, depends_on_number)
      SELECT project_id, number, number - 1 - a FROM picks
      UNION ALL
      SELECT project_id, number, number - 1 - (a + b) % w FROM picks WHERE w >= 2
      UNION ALL
      SELECT project_id, number, number - 1 - (a + c) % w FROM picks WHERE w >= 3 AND number % 10 = 0
      ON CONFLICT DO NOTHING;
      ANALYZE task_dependencies;''');

    await _step('Task statuses', '''
      -- How far each project has got: nothing before it starts, everything
      -- for most long-finished ones, otherwise somewhat behind its calendar.
      CREATE TEMP TABLE seed_progress AS
      SELECT pr.id, s.size, current_date >= pr.planned_start AS started,
             floor(s.size * CASE
               WHEN current_date < pr.planned_start THEN 0
               WHEN current_date >= pr.planned_end + 60 AND pr.id % 7 <> 0 THEN 1
               ELSE least(1, (current_date - pr.planned_start)::numeric
                             / greatest(pr.planned_end - pr.planned_start, 1))
                    * (0.75 + 0.25 * ((pr.id * 7919) % 100) / 100.0)
             END)::int AS done_upto
        FROM projects pr JOIN seed_task_sizes s ON s.id = pr.id;

      UPDATE tasks t SET status = 'done'
        FROM seed_progress g
       WHERE t.project_id = g.id AND t.number <= g.done_upto;

      -- The next few, where everything they wait on is done, are under way.
      UPDATE tasks t SET status = 'in_progress'
        FROM seed_progress g
       WHERE t.project_id = g.id
         AND g.done_upto < g.size
         AND t.number > g.done_upto
         AND t.number <= g.done_upto + greatest(1, g.size / 40)
         AND g.started
         AND NOT EXISTS (SELECT 1 FROM task_dependencies d
                           JOIN tasks u ON u.project_id = d.project_id AND u.number = d.depends_on_number
                          WHERE d.project_id = t.project_id AND d.task_number = t.number
                            AND u.status <> 'done');''');

    await _step('Blocked flags and task counters', '''
      SELECT count(refresh_project_task_stats(id)) FROM projects;''');

    await _step('Delivery plan', '''
      CREATE TEMP TABLE seed_people AS
      SELECT project_id, array_agg(user_id ORDER BY user_id) AS members
        FROM project_members GROUP BY project_id;
      CREATE TEMP TABLE seed_managers AS
      SELECT array_agg(id ORDER BY id) AS ids FROM users WHERE app_role = 'store_manager';

      -- Each project takes deliveries from two weeks before it starts until
      -- it ends (or today), at the same rate per day across the company.
      CREATE TEMP TABLE seed_windows AS
      SELECT id AS project_id, ws, we - ws + 1 AS days
        FROM (SELECT id, greatest(planned_start - 14, current_date - 1825) AS ws,
                     least(planned_end, current_date) AS we FROM projects) x
       WHERE we >= ws;

      CREATE TEMP TABLE seed_out AS
      WITH w AS (SELECT project_id, ws, days, sum(days) OVER (ORDER BY project_id) - days AS cum
                   FROM seed_windows),
           a AS (SELECT array_agg(cum::float8 ORDER BY project_id) AS starts,
                        array_agg(project_id ORDER BY project_id) AS ids,
                        array_agg(ws ORDER BY project_id) AS window_starts,
                        sum(days)::float8 AS total
                   FROM w)
      SELECT r.i AS tmp_id, a.ids[b.k] AS project_id,
             least(now() - interval '5 minutes',
                   a.window_starts[b.k]::timestamptz + (r.v - a.starts[b.k]) * interval '1 day') AS sent_at,
             1 + floor(random() * 16)::int AS line_count,
             floor(random() * ${p.materialsPerProject})::int AS slot_seed,
             random() AS roll,
             NULL::text AS status, NULL::timestamptz AS closed_at,
             NULL::bigint AS sent_by, NULL::bigint AS closed_by
        FROM a
       -- random() per row: a LATERAL that ignores the outer row runs once.
       CROSS JOIN LATERAL (SELECT i, random() * a.total AS v
                             FROM generate_series(1, ${p.deliveriesOut}) i) r
       CROSS JOIN LATERAL (SELECT width_bucket(r.v, a.starts) AS k) b;

      UPDATE seed_out SET status = CASE
        WHEN sent_at > now() - interval '7 days' AND roll < 0.5 THEN 'in_transit'
        WHEN roll < 0.94 THEN 'delivered' WHEN roll < 0.97 THEN 'rejected' ELSE 'cancelled' END;
      -- Sent by a store manager; recorded or rejected by a project member;
      -- cancelled by a store manager.
      UPDATE seed_out o SET
        closed_at = CASE WHEN o.status <> 'in_transit'
                         THEN least(now() - interval '1 minute', o.sent_at + (1 + random() * 71) * interval '1 hour') END,
        sent_by = m.ids[1 + floor(random() * cardinality(m.ids))::int],
        closed_by = CASE o.status
                      WHEN 'in_transit' THEN NULL
                      WHEN 'cancelled' THEN m.ids[1 + floor(random() * cardinality(m.ids))::int]
                      ELSE pp.members[1 + floor(random() * cardinality(pp.members))::int] END
        FROM seed_managers m, seed_people pp
       WHERE pp.project_id = o.project_id;

      -- Returns: some received deliveries send part of their material back.
      CREATE TEMP TABLE seed_back AS
      SELECT row_number() OVER () AS tmp_id, o.tmp_id AS source_tmp_id, o.project_id,
             o.closed_at + random() * least(interval '30 days', now() - o.closed_at) AS sent_at,
             1 + floor(random() * 4)::int AS line_count, random() AS roll,
             NULL::text AS status, NULL::timestamptz AS closed_at,
             NULL::bigint AS sent_by, NULL::bigint AS closed_by
        FROM (SELECT * FROM seed_out WHERE status = 'delivered'
               ORDER BY random() LIMIT ${p.deliveriesBack}) o;
      UPDATE seed_back SET status = CASE
        WHEN sent_at > now() - interval '7 days' AND roll < 0.5 THEN 'in_transit'
        WHEN roll < 0.9 THEN 'delivered' WHEN roll < 0.95 THEN 'rejected' ELSE 'cancelled' END;
      UPDATE seed_back b SET
        closed_at = CASE WHEN b.status <> 'in_transit'
                         THEN least(now() - interval '1 minute', b.sent_at + (1 + random() * 71) * interval '1 hour') END,
        sent_by = pp.members[1 + floor(random() * cardinality(pp.members))::int],
        closed_by = CASE b.status
                      WHEN 'in_transit' THEN NULL
                      WHEN 'cancelled' THEN pp.members[1 + floor(random() * cardinality(pp.members))::int]
                      ELSE m.ids[1 + floor(random() * cardinality(m.ids))::int] END
        FROM seed_managers m, seed_people pp
       WHERE pp.project_id = b.project_id;

      -- One numbering for both, in the order they were sent.
      CREATE TEMP TABLE seed_deliveries AS
      SELECT row_number() OVER (ORDER BY sent_at, kind, tmp_id) AS id, x.*
        FROM (SELECT 'out' AS kind, tmp_id, NULL::bigint AS source_tmp_id, project_id,
                     'to_project' AS direction, status, sent_at, sent_by, closed_at, closed_by,
                     line_count, slot_seed
                FROM seed_out
              UNION ALL
              SELECT 'back', tmp_id, source_tmp_id, project_id, 'to_company', status, sent_at,
                     sent_by, closed_at, closed_by, line_count, 0
                FROM seed_back) x;
      CREATE INDEX ON seed_deliveries (kind, tmp_id);
      ANALYZE seed_deliveries;''');

    await _step('Deliveries', '''
      INSERT INTO deliveries (id, project_id, direction, status, sent_by, sent_at, closed_by, closed_at)
      OVERRIDING SYSTEM VALUE
      SELECT id, project_id, direction, status, sent_by, sent_at, closed_by, closed_at
        FROM seed_deliveries ORDER BY id;
      ANALYZE deliveries;''');

    await _step('Delivery lines', '''
      -- Each project draws from its own slice of the catalogue.
      INSERT INTO delivery_lines (delivery_id, material_id, quantity)
      SELECT d.id,
             1 + ((d.project_id::bigint * 7919
                   + ((d.slot_seed + j * 7) % ${p.materialsPerProject}) * 104729) % ${p.materials}),
             (1 + floor(random() * 200))::numeric
        FROM seed_deliveries d
       CROSS JOIN LATERAL generate_series(0, d.line_count - 1) j
       WHERE d.kind = 'out'
      ON CONFLICT DO NOTHING;
      ANALYZE delivery_lines;

      -- A return carries part (10-30%) of some lines of the delivery it
      -- mirrors, so a project store can never give back more than it got.
      INSERT INTO delivery_lines (delivery_id, material_id, quantity)
      SELECT b.id, l.material_id, greatest(1, floor(l.quantity * (0.1 + random() * 0.2)))
        FROM seed_deliveries b
        JOIN seed_deliveries src ON src.kind = 'out' AND src.tmp_id = b.source_tmp_id
       CROSS JOIN LATERAL (SELECT material_id, quantity FROM delivery_lines
                            WHERE delivery_id = src.id ORDER BY material_id LIMIT b.line_count) l
       WHERE b.kind = 'back';''');

    await _step('Stock', '''
      -- A project store holds what it received, less what it sent back
      -- (unless the return was rejected or cancelled).
      INSERT INTO project_stock (project_id, material_id, quantity, last_delivery_at)
      SELECT d.project_id, l.material_id,
             sum(CASE WHEN d.direction = 'to_project' AND d.status = 'delivered' THEN l.quantity
                      WHEN d.direction = 'to_company' AND d.status IN ('in_transit', 'delivered')
                        THEN -l.quantity
                      ELSE 0 END),
             max(CASE WHEN d.direction = 'to_project' AND d.status = 'delivered' THEN d.closed_at
                      WHEN d.direction = 'to_company' THEN d.sent_at END)
        FROM deliveries d
        JOIN delivery_lines l ON l.delivery_id = d.id
       GROUP BY d.project_id, l.material_id
      HAVING bool_or(d.direction = 'to_project' AND d.status = 'delivered');

      CREATE TEMP TABLE seed_flows AS
      SELECT l.material_id,
             coalesce(sum(l.quantity) FILTER (WHERE d.direction = 'to_project'
                                              AND d.status = 'in_transit'), 0) AS in_transit,
             coalesce(sum(l.quantity) FILTER (WHERE d.direction = 'to_project'
                                              AND d.status IN ('in_transit', 'delivered')), 0) AS sent,
             coalesce(sum(l.quantity) FILTER (WHERE d.direction = 'to_company'
                                              AND d.status = 'delivered'), 0) AS returned
        FROM deliveries d JOIN delivery_lines l ON l.delivery_id = d.id
       GROUP BY l.material_id;

      -- What is on the company shelf today: a mix of out of stock, low and
      -- available against each material's reorder point.
      INSERT INTO company_stock (material_id, quantity, in_transit, reorder_point, updated_at)
      SELECT m.id, q.quantity, coalesce(f.in_transit, 0), r.point, now()
        FROM materials m
        LEFT JOIN seed_flows f ON f.material_id = m.id
       CROSS JOIN LATERAL (SELECT (((m.id * 37) % 20) * 10)::numeric AS point) r
       CROSS JOIN LATERAL (SELECT CASE WHEN m.id % 20 = 0 THEN 0
                                       WHEN m.id % 7 = 0 THEN floor(random() * (r.point + 1))
                                       ELSE r.point + 1 + floor(random() * 500) END::numeric AS quantity) q;

      -- Supplier additions that account for all of it: shelf + sent - returned.
      INSERT INTO stock_additions (material_id, quantity, added_by, added_at, note)
      SELECT s.material_id, part.quantity,
             m.ids[1 + floor(random() * cardinality(m.ids))::int], part.at, 'Supplier delivery'
        FROM (SELECT cs.material_id,
                     cs.quantity + coalesce(f.sent, 0) - coalesce(f.returned, 0) AS total,
                     1 + cs.material_id % 5 AS parts
                FROM company_stock cs LEFT JOIN seed_flows f USING (material_id)) s
       CROSS JOIN seed_managers m
       CROSS JOIN LATERAL generate_series(1, s.parts) k
       CROSS JOIN LATERAL (
         SELECT CASE WHEN k < s.parts THEN floor(s.total / s.parts)
                     ELSE s.total - floor(s.total / s.parts) * (s.parts - 1) END AS quantity,
                now() - interval '6 years' + (k::float / (s.parts + 1)) * interval '6 years'
                  + random() * interval '30 days' AS at) part
       WHERE s.total > 0 AND part.quantity > 0;''');

    await _step(
      'Sequences',
      '''
      -- One statement: the driver takes one result set per simple query.
      SELECT setval(pg_get_serial_sequence('users', 'id'), (SELECT max(id) FROM users)),
             setval(pg_get_serial_sequence('materials', 'id'), (SELECT max(id) FROM materials)),
             setval(pg_get_serial_sequence('deliveries', 'id'), (SELECT max(id) FROM deliveries));''',
    );

    await _verifyReferences();
    await _step('Vacuum and analyze', 'VACUUM (ANALYZE)');

    _log(
      'Seeded in ${(total.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
    );
  }

  /// Row counts per table and a few invariants, for the log and the tests.
  Future<Map<String, int>> summary() async {
    final rows = await _connection.execute(
      '''
      SELECT 'users', count(*) FROM users
      UNION ALL SELECT 'projects', count(*) FROM projects
      UNION ALL SELECT 'project_members', count(*) FROM project_members
      UNION ALL SELECT 'project_invitations', count(*) FROM project_invitations
      UNION ALL SELECT 'tasks', count(*) FROM tasks
      UNION ALL SELECT 'task_dependencies', count(*) FROM task_dependencies
      UNION ALL SELECT 'materials', count(*) FROM materials
      UNION ALL SELECT 'deliveries', count(*) FROM deliveries
      UNION ALL SELECT 'delivery_lines', count(*) FROM delivery_lines
      UNION ALL SELECT 'project_stock', count(*) FROM project_stock
      UNION ALL SELECT 'stock_additions', count(*) FROM stock_additions
      UNION ALL SELECT 'largest_project_tasks', coalesce(max(last_task_number), 0) FROM projects
      UNION ALL SELECT 'largest_project_members', coalesce(max(member_count), 0) FROM projects
      UNION ALL SELECT 'started_tasks_waiting_on_unfinished', count(*)
        FROM tasks t JOIN task_dependencies d
          ON d.project_id = t.project_id AND d.task_number = t.number
        JOIN tasks u ON u.project_id = d.project_id AND u.number = d.depends_on_number
       WHERE t.status <> 'not_started' AND u.status <> 'done'
      UNION ALL SELECT 'company_stock_mismatches', count(*)
        FROM company_stock cs
        LEFT JOIN (SELECT material_id, sum(quantity) AS added FROM stock_additions GROUP BY 1) a
          USING (material_id)
        LEFT JOIN (SELECT l.material_id,
                          sum(l.quantity) FILTER (WHERE d.direction = 'to_project'
                                                  AND d.status IN ('in_transit', 'delivered')) AS sent,
                          sum(l.quantity) FILTER (WHERE d.direction = 'to_company'
                                                  AND d.status = 'delivered') AS returned
                     FROM deliveries d JOIN delivery_lines l ON l.delivery_id = d.id GROUP BY 1) f
          USING (material_id)
       WHERE cs.quantity <> coalesce(a.added, 0) - coalesce(f.sent, 0) + coalesce(f.returned, 0)''',
    );
    return {for (final row in rows) row[0]! as String: row[1]! as int};
  }

  var _checkedPerRow = true;

  /// Turns off per-row trigger work, foreign key checks included, for this
  /// session only. Checking 6 million references one row at a time takes
  /// minutes; [_verifyReferences] checks them all afterwards in a few
  /// set-based queries instead. Needs the database owner's superuser role,
  /// which the compose setup has; otherwise the per-row checks stay on.
  Future<bool> _skipPerRowChecks() async {
    try {
      await _connection.execute("SET session_replication_role = 'replica'");
      return true;
    } on ServerException {
      _log('  (not a superuser: keeping per-row foreign key checks; slower)');
      return false;
    }
  }

  /// Every foreign key, checked in bulk. Fails the seed if any reference is
  /// broken, so skipping the per-row checks never lets bad data through.
  Future<void> _verifyReferences() async {
    if (_checkedPerRow) return;
    const checks = {
      'tasks.project_id':
          'SELECT count(*) FROM tasks c WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id)',
      'task_dependencies.task':
          'SELECT count(*) FROM task_dependencies c WHERE NOT EXISTS (SELECT 1 FROM tasks t WHERE t.project_id = c.project_id AND t.number = c.task_number)',
      'task_dependencies.depends_on':
          'SELECT count(*) FROM task_dependencies c WHERE NOT EXISTS (SELECT 1 FROM tasks t WHERE t.project_id = c.project_id AND t.number = c.depends_on_number)',
      'projects.created_by':
          'SELECT count(*) FROM projects c WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.created_by)',
      'project_members':
          'SELECT count(*) FROM project_members c WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.user_id)',
      'project_invitations':
          'SELECT count(*) FROM project_invitations c WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.invitee_id) OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.invited_by) OR (c.closed_by IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.closed_by))',
      'deliveries':
          'SELECT count(*) FROM deliveries c WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.sent_by) OR (c.closed_by IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.closed_by))',
      'delivery_lines.delivery_id':
          'SELECT count(*) FROM delivery_lines c WHERE NOT EXISTS (SELECT 1 FROM deliveries d WHERE d.id = c.delivery_id)',
      'delivery_lines.material_id':
          'SELECT count(*) FROM delivery_lines c WHERE NOT EXISTS (SELECT 1 FROM materials m WHERE m.id = c.material_id)',
      'project_stock':
          'SELECT count(*) FROM project_stock c WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) OR NOT EXISTS (SELECT 1 FROM materials m WHERE m.id = c.material_id)',
      'company_stock.material_id':
          'SELECT count(*) FROM company_stock c WHERE NOT EXISTS (SELECT 1 FROM materials m WHERE m.id = c.material_id)',
      'stock_additions':
          'SELECT count(*) FROM stock_additions c WHERE NOT EXISTS (SELECT 1 FROM materials m WHERE m.id = c.material_id) OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = c.added_by)',
    };
    final watch = Stopwatch()..start();
    for (final MapEntry(key: name, value: sql) in checks.entries) {
      final broken = (await _connection.execute(sql)).single[0]! as int;
      if (broken > 0) {
        throw StateError('Seed produced $broken broken references in $name');
      }
    }
    await _connection.execute("SET session_replication_role = 'origin'");
    _log(
      '  ${'Check every reference'.padRight(34)} '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1).padLeft(6)} s',
    );
  }

  Future<void> _step(String name, String sql) async {
    final watch = Stopwatch()..start();
    await _connection.execute(sql, queryMode: QueryMode.simple);
    _log(
      '  ${name.padRight(34)} ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1).padLeft(6)} s',
    );
  }
}
