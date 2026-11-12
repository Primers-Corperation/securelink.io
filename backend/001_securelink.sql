-- SecureLink backend: emergency alerts routed to the nearest responder agencies.
--
-- Lives in the Primers ID project, so everyone signs in with their Primers ID and every call below
-- runs as that person (auth.uid()). All data sits in schema `securelink` with row level security on
-- and no policies: the only way in is through the role-checked functions in `public` below.
--
-- Roles (securelink.members.role):
--   citizen         raises alerts, sees only their own
--   responder       member of one agency; sees alerts routed to that agency, with precise location
--   agency_admin    responder who also sees the agency's members
--   platform_admin  Primers operators; see metadata (counts, states, times) freely, but victim
--                   content (precise location, trail, audio) only through a break-glass grant:
--                   one incident, a written reason, an expiry, every read audited.
--
-- Routing: an alert goes to every active agency whose kinds match its category and whose service
-- radius covers it. Unacknowledged after 2 minutes, it escalates: the radius doubles (up to 3 times)
-- and it is re-sent. A phone that goes silent never closes an alert (dead-man's switch): it is
-- flagged "signal lost" and stays open until a responder resolves it or the victim marks themself safe.

create schema if not exists securelink;
revoke all on schema securelink from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------
create table securelink.agencies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  kinds text[] not null check (kinds <@ array['police','fire','ambulance','road_safety','disaster','civil_defence','campus_security']::text[] and cardinality(kinds) > 0),
  command text,
  states text[] not null default '{}',
  base_lat double precision not null check (base_lat between -90 and 90),
  base_lng double precision not null check (base_lng between -180 and 180),
  radius_km integer not null default 25 check (radius_km between 1 and 500),
  contact_name text,
  contact_phone text,
  contact_email text,
  seat_limit integer not null default 50 check (seat_limit between 1 and 5000),
  status text not null default 'active' check (status in ('active','suspended')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table securelink.members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'citizen' check (role in ('citizen','responder','agency_admin','platform_admin')),
  agency_id uuid references securelink.agencies(id) on delete set null,
  status text not null default 'active' check (status in ('active','suspended')),
  -- Community alerts: only a coarse ~5 km grid cell is stored, never a precise position.
  area_cell text,
  area_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (role not in ('responder','agency_admin') or agency_id is not null)
);
create index on securelink.members (agency_id);

create table securelink.invites (
  id uuid primary key default gen_random_uuid(),
  code_hash text not null unique,
  code_hint text not null,
  agency_id uuid not null references securelink.agencies(id) on delete cascade,
  grants_role text not null default 'responder' check (grants_role in ('responder','agency_admin')),
  max_uses integer not null default 1 check (max_uses between 1 and 500),
  use_count integer not null default 0,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on securelink.invites (agency_id);

create table securelink.incidents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('police','fire','accident','medical','general')),
  trigger text not null default 'button' check (trigger in ('button','shake','sos_key','volume','tap')),
  status text not null default 'active' check (status in ('active','acknowledged','resolved','cancelled')),
  lat double precision check (lat between -90 and 90),
  lng double precision check (lng between -180 and 180),
  accuracy_m integer,
  note text check (length(note) <= 500),
  agency_id uuid references securelink.agencies(id) on delete set null,       -- who took it
  acknowledged_by uuid references auth.users(id) on delete set null,
  resolved_by uuid references auth.users(id) on delete set null,
  outcome text check (length(outcome) <= 500),
  escalations integer not null default 0,
  unrouted boolean not null default false,                                    -- no agency covers it
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  escalated_at timestamptz,
  signal_lost_at timestamptz,
  closed_at timestamptz
);
create index on securelink.incidents (user_id, started_at desc);
create index on securelink.incidents (status) where status in ('active','acknowledged');
create index on securelink.incidents (started_at desc);
create index on securelink.incidents (agency_id);
create index on securelink.incidents (acknowledged_by);
create index on securelink.incidents (resolved_by);

-- Agencies an alert was sent to (all candidates, not just the one that took it).
create table securelink.incident_routes (
  incident_id uuid not null references securelink.incidents(id) on delete cascade,
  agency_id uuid not null references securelink.agencies(id) on delete cascade,
  distance_km numeric(7,2),
  routed_at timestamptz not null default now(),
  primary key (incident_id, agency_id)
);
create index on securelink.incident_routes (agency_id);

create table securelink.incident_points (
  id bigint generated always as identity primary key,
  incident_id uuid not null references securelink.incidents(id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  accuracy_m integer,
  at timestamptz not null default now()
);
create index on securelink.incident_points (incident_id, at);

create table securelink.incident_audio (
  id bigint generated always as identity primary key,
  incident_id uuid not null references securelink.incidents(id) on delete cascade,
  path text not null unique,
  seconds integer check (seconds between 0 and 600),
  at timestamptz not null default now()
);
create index on securelink.incident_audio (incident_id);

create table securelink.incident_events (
  id bigint generated always as identity primary key,
  incident_id uuid not null references securelink.incidents(id) on delete cascade,
  kind text not null check (kind in ('raised','routed','unrouted','acknowledged','escalated','signal_lost','signal_back','resolved','cancelled')),
  actor uuid references auth.users(id) on delete set null,
  agency_id uuid references securelink.agencies(id) on delete set null,
  detail jsonb not null default '{}',
  at timestamptz not null default now()
);
create index on securelink.incident_events (incident_id, at);
create index on securelink.incident_events (actor);
create index on securelink.incident_events (agency_id);

create table securelink.breakglass (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references securelink.incidents(id) on delete cascade,
  operator uuid not null references auth.users(id) on delete cascade,
  reason text not null check (length(trim(reason)) between 10 and 500),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  use_count integer not null default 0,
  created_at timestamptz not null default now()
);
create index on securelink.breakglass (incident_id);
create index on securelink.breakglass (operator);

create table securelink.audit (
  id bigint generated always as identity primary key,
  actor uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id text,
  detail jsonb not null default '{}',
  at timestamptz not null default now()
);
create index on securelink.audit (at desc);
create index on securelink.audit (actor);

-- Abuse limits (per user, rolling hour).
create table securelink.rate (
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  at timestamptz not null default now()
);
create index on securelink.rate (user_id, action, at);

do $$ declare t text; begin
  foreach t in array array['agencies','members','invites','incidents','incident_routes','incident_points','incident_audio','incident_events','breakglass','audit','rate'] loop
    execute format('alter table securelink.%I enable row level security', t);
    execute format('revoke all on securelink.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Helpers (internal; not callable from the API)
-- ---------------------------------------------------------------------------------------------
create function securelink.km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable set search_path = '' as $$
  select 6371.0 * 2 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)));
$$;

-- ~5.5 km grid cells for community alerts.
create function securelink.cell(lat double precision, lng double precision)
returns text language sql immutable set search_path = '' as $$
  select floor(lat / 0.05)::bigint::text || '_' || floor(lng / 0.05)::bigint::text;
$$;

create function securelink.kinds_for(category text)
returns text[] language sql immutable set search_path = '' as $$
  select case category
    when 'police' then array['police','civil_defence','campus_security']
    when 'fire' then array['fire','disaster']
    when 'accident' then array['road_safety','ambulance']
    when 'medical' then array['ambulance']
    else array['police','fire','ambulance','road_safety','disaster','civil_defence','campus_security'] end;
$$;

-- The caller's membership; creates a citizen row on first use. Raises if suspended.
create function securelink.me()
returns securelink.members language plpgsql security definer set search_path = '' as $$
declare m securelink.members;
begin
  if auth.uid() is null then raise exception 'Sign in with your Primers ID first' using errcode = '28000'; end if;
  insert into securelink.members (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select * into m from securelink.members where user_id = auth.uid();
  if m.status <> 'active' then raise exception 'This SecureLink account is suspended' using errcode = '42501'; end if;
  return m;
end $$;

create function securelink.require_admin()
returns securelink.members language plpgsql security definer set search_path = '' as $$
declare m securelink.members;
begin
  m := securelink.me();
  -- "Not found" rather than "forbidden": the portal does not confirm it exists to other accounts.
  if m.role <> 'platform_admin' then raise exception 'Not found' using errcode = 'P0002'; end if;
  return m;
end $$;

create function securelink.limit_rate(p_action text, p_per_hour integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from securelink.rate where user_id = auth.uid() and action = p_action and at < now() - interval '1 hour';
  if (select count(*) from securelink.rate where user_id = auth.uid() and action = p_action) >= p_per_hour then
    raise exception 'Too many requests. Please wait a little and try again.' using errcode = '54000';
  end if;
  insert into securelink.rate (user_id, action) values (auth.uid(), p_action);
end $$;

create function securelink.log(p_action text, p_type text, p_id text, p_detail jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into securelink.audit (actor, action, target_type, target_id, detail) values (auth.uid(), p_action, p_type, p_id, coalesce(p_detail, '{}'));
$$;

-- Live updates over Supabase Realtime (private channels; who may listen is set by the policy below).
create function securelink.notify(p_topic text, p_event text, p_payload jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(p_payload, p_event, p_topic, true);
exception when others then null;  -- a failed broadcast must never block an emergency write
end $$;

-- Is the caller a responder of an agency this incident was routed to?
create function securelink.responder_for(p_incident uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from securelink.members m
    join securelink.incident_routes r on r.agency_id = m.agency_id and r.incident_id = p_incident
    where m.user_id = auth.uid() and m.status = 'active' and m.role in ('responder','agency_admin'));
$$;

-- A live break-glass grant for this incident held by the caller.
create function securelink.grant_for(p_incident uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select b.id from securelink.breakglass b
  join securelink.members m on m.user_id = b.operator and m.role = 'platform_admin' and m.status = 'active'
  where b.incident_id = p_incident and b.operator = auth.uid() and b.revoked_at is null and b.expires_at > now()
  order by b.created_at desc limit 1;
$$;

create function securelink.summary(i securelink.incidents)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', i.id, 'category', i.category, 'trigger', i.trigger, 'status', i.status,
    'startedAt', i.started_at, 'acknowledgedAt', i.acknowledged_at, 'closedAt', i.closed_at,
    'escalations', i.escalations, 'unrouted', i.unrouted, 'signalLost', i.signal_lost_at is not null,
    'blind', i.lat is null, 'agency', (select name from securelink.agencies where id = i.agency_id));
$$;

-- Send an alert to every matching agency in range (radius widened by escalations).
create function securelink.route(p_incident uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare i securelink.incidents; n integer := 0; a record; widen numeric;
begin
  select * into i from securelink.incidents where id = p_incident;
  if i.id is null or i.lat is null then return 0; end if;
  widen := power(2, least(i.escalations, 3));
  for a in
    select g.id, securelink.km(i.lat, i.lng, g.base_lat, g.base_lng) as d
    from securelink.agencies g
    where g.status = 'active' and g.kinds && securelink.kinds_for(i.category)
      and securelink.km(i.lat, i.lng, g.base_lat, g.base_lng) <= g.radius_km * widen
  loop
    insert into securelink.incident_routes (incident_id, agency_id, distance_km) values (i.id, a.id, round(a.d::numeric, 2))
      on conflict do nothing;
    if found then
      n := n + 1;
      insert into securelink.incident_events (incident_id, kind, agency_id, detail) values (i.id, 'routed', a.id, jsonb_build_object('distanceKm', round(a.d::numeric, 1)));
    end if;
    perform securelink.notify('sl:agency:' || a.id, 'incident', securelink.summary(i) || jsonb_build_object('distanceKm', round(a.d::numeric, 1)));
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Citizen API
-- ---------------------------------------------------------------------------------------------
create function public.securelink_me()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members; inc securelink.incidents;
begin
  m := securelink.me();
  select * into inc from securelink.incidents where user_id = auth.uid() and status in ('active','acknowledged') order by started_at desc limit 1;
  return jsonb_build_object(
    'userId', m.user_id, 'role', m.role, 'communityAlerts', m.area_cell is not null,
    'agency', (select jsonb_build_object('id', g.id, 'name', g.name, 'kinds', g.kinds, 'status', g.status) from securelink.agencies g where g.id = m.agency_id),
    'activeIncident', case when inc.id is null then null else securelink.summary(inc) end);
end $$;

create function public.securelink_raise(p_category text, p_trigger text default 'button', p_lat double precision default null,
  p_lng double precision default null, p_accuracy integer default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members; inc securelink.incidents; routed integer := 0; c text;
begin
  m := securelink.me();
  -- One open alert per person: pressing again returns the one already running.
  select * into inc from securelink.incidents where user_id = auth.uid() and status in ('active','acknowledged') order by started_at desc limit 1;
  if inc.id is not null then return securelink.summary(inc) || jsonb_build_object('existing', true); end if;
  perform securelink.limit_rate('raise', 6);
  if p_category not in ('police','fire','accident','medical','general') then p_category := 'general'; end if;
  if p_trigger not in ('button','shake','sos_key','volume','tap') then p_trigger := 'button'; end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng is null or p_lng not between -180 and 180) then p_lat := null; p_lng := null; end if;
  insert into securelink.incidents (user_id, category, trigger, lat, lng, accuracy_m, note)
    values (auth.uid(), p_category, p_trigger, p_lat, case when p_lat is null then null else p_lng end, p_accuracy, nullif(left(trim(coalesce(p_note, '')), 500), ''))
    returning * into inc;
  insert into securelink.incident_events (incident_id, kind, actor, detail) values (inc.id, 'raised', auth.uid(), jsonb_build_object('trigger', p_trigger, 'blind', p_lat is null));
  if p_lat is not null then
    insert into securelink.incident_points (incident_id, lat, lng, accuracy_m) values (inc.id, p_lat, p_lng, p_accuracy);
    routed := securelink.route(inc.id);
    -- Community alert to people nearby: category and a coarse area only, never the person or exact spot.
    foreach c in array array[securelink.cell(p_lat, p_lng), securelink.cell(p_lat + 0.05, p_lng), securelink.cell(p_lat - 0.05, p_lng),
                             securelink.cell(p_lat, p_lng + 0.05), securelink.cell(p_lat, p_lng - 0.05)] loop
      perform securelink.notify('sl:area:' || c, 'nearby', jsonb_build_object('category', p_category, 'cell', securelink.cell(p_lat, p_lng), 'at', now()));
    end loop;
  end if;
  if routed = 0 then
    update securelink.incidents set unrouted = true where id = inc.id returning * into inc;
    insert into securelink.incident_events (incident_id, kind, detail) values (inc.id, 'unrouted', jsonb_build_object('blind', p_lat is null));
  end if;
  perform securelink.notify('sl:ops', 'incident', securelink.summary(inc));
  select * into inc from securelink.incidents where id = inc.id;
  return securelink.summary(inc) || jsonb_build_object('routedTo', routed);
end $$;

-- Location heartbeat while an alert is open. Also the dead-man's switch input.
create function public.securelink_ping(p_incident uuid, p_lat double precision default null, p_lng double precision default null, p_accuracy integer default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare inc securelink.incidents; last_at timestamptz; first_fix boolean;
begin
  perform securelink.me();
  select * into inc from securelink.incidents where id = p_incident and user_id = auth.uid();
  if inc.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if inc.status not in ('active','acknowledged') then return securelink.summary(inc); end if;
  first_fix := inc.lat is null and p_lat is not null;
  if inc.signal_lost_at is not null then
    insert into securelink.incident_events (incident_id, kind) values (inc.id, 'signal_back');
  end if;
  update securelink.incidents set last_seen_at = now(), signal_lost_at = null,
    lat = coalesce(p_lat, lat), lng = case when p_lat is null then lng else p_lng end, accuracy_m = coalesce(p_accuracy, accuracy_m)
    where id = inc.id returning * into inc;
  if p_lat is not null and p_lat between -90 and 90 and p_lng between -180 and 180 then
    select max(at) into last_at from securelink.incident_points where incident_id = inc.id;
    if last_at is null or last_at < now() - interval '5 seconds' then
      insert into securelink.incident_points (incident_id, lat, lng, accuracy_m) values (inc.id, p_lat, p_lng, p_accuracy);
      if inc.agency_id is not null then
        perform securelink.notify('sl:agency:' || inc.agency_id, 'position', jsonb_build_object('id', inc.id, 'lat', p_lat, 'lng', p_lng, 'accuracy', p_accuracy, 'at', now()));
      end if;
    end if;
    -- A "blind" alert that now has a location can finally be routed.
    if first_fix then
      if securelink.route(inc.id) > 0 then update securelink.incidents set unrouted = false where id = inc.id returning * into inc; end if;
    end if;
  end if;
  return securelink.summary(inc);
end $$;

create function public.securelink_add_audio(p_incident uuid, p_path text, p_seconds integer default null)
returns void language plpgsql security definer set search_path = '' as $$
declare inc securelink.incidents;
begin
  perform securelink.me();
  select * into inc from securelink.incidents where id = p_incident and user_id = auth.uid() and status in ('active','acknowledged');
  if inc.id is null or p_path is null or split_part(p_path, '/', 1) <> inc.id::text or p_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{8,64}\.(webm|ogg|mp4|m4a)$' then
    raise exception 'Not found' using errcode = 'P0002';
  end if;
  insert into securelink.incident_audio (incident_id, path, seconds) values (inc.id, p_path, p_seconds) on conflict (path) do nothing;
  if inc.agency_id is not null then
    perform securelink.notify('sl:agency:' || inc.agency_id, 'audio', jsonb_build_object('id', inc.id));
  end if;
end $$;

-- The victim marks themself safe.
create function public.securelink_cancel(p_incident uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare inc securelink.incidents; a uuid;
begin
  perform securelink.me();
  update securelink.incidents set status = 'cancelled', closed_at = now(), outcome = coalesce(nullif(left(trim(coalesce(p_reason, '')), 500), ''), 'Marked safe by the person who raised it')
    where id = p_incident and user_id = auth.uid() and status in ('active','acknowledged') returning * into inc;
  if inc.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  insert into securelink.incident_events (incident_id, kind, actor) values (inc.id, 'cancelled', auth.uid());
  for a in select agency_id from securelink.incident_routes where incident_id = inc.id loop
    perform securelink.notify('sl:agency:' || a, 'incident', securelink.summary(inc));
  end loop;
  perform securelink.notify('sl:ops', 'incident', securelink.summary(inc));
  return securelink.summary(inc);
end $$;

-- The victim's view of their own alert.
create function public.securelink_my_incident(p_incident uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare inc securelink.incidents;
begin
  perform securelink.me();
  select * into inc from securelink.incidents where id = p_incident and user_id = auth.uid();
  if inc.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  return securelink.summary(inc) || jsonb_build_object(
    'routedTo', (select count(*) from securelink.incident_routes where incident_id = inc.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'agency', g.name) order by e.at), '[]')
               from securelink.incident_events e left join securelink.agencies g on g.id = e.agency_id
               where e.incident_id = inc.id and e.kind in ('raised','acknowledged','escalated','resolved','cancelled','unrouted')));
end $$;

create function public.securelink_my_history(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.me();
  return (select coalesce(jsonb_agg(securelink.summary(i) order by i.started_at desc), '[]')
          from (select * from securelink.incidents where user_id = auth.uid() order by started_at desc limit least(greatest(p_limit, 1), 100)) i);
end $$;

-- Community alerts opt-in: store only the coarse cell of where the person is.
create function public.securelink_set_area(p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  perform securelink.me();
  c := case when p_lat between -90 and 90 and p_lng between -180 and 180 then securelink.cell(p_lat, p_lng) end;
  update securelink.members set area_cell = c, area_at = case when c is null then null else now() end, updated_at = now() where user_id = auth.uid();
  return jsonb_build_object('cell', c, 'neighbours', case when c is null then '[]'::jsonb else to_jsonb(array[c,
    securelink.cell(p_lat + 0.05, p_lng), securelink.cell(p_lat - 0.05, p_lng), securelink.cell(p_lat, p_lng + 0.05), securelink.cell(p_lat, p_lng - 0.05)]) end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- Responder API
-- ---------------------------------------------------------------------------------------------
create function public.securelink_join(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members; inv securelink.invites; seats integer; g securelink.agencies;
begin
  m := securelink.me();
  perform securelink.limit_rate('join', 10);
  if m.role = 'platform_admin' then raise exception 'Platform operators cannot join an agency' using errcode = '22023'; end if;
  select * into inv from securelink.invites
    where code_hash = encode(extensions.digest(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex')
      and revoked_at is null and expires_at > now() and use_count < max_uses
    for update;
  if inv.id is null then raise exception 'That code is not valid or has expired' using errcode = '22023'; end if;
  select * into g from securelink.agencies where id = inv.agency_id;
  if g.status <> 'active' then raise exception 'That agency is not active' using errcode = '22023'; end if;
  select count(*) into seats from securelink.members where agency_id = g.id and role in ('responder','agency_admin') and status = 'active';
  if seats >= g.seat_limit and m.agency_id is distinct from g.id then raise exception 'This agency has no free seats' using errcode = '22023'; end if;
  update securelink.invites set use_count = use_count + 1 where id = inv.id;
  update securelink.members set role = inv.grants_role, agency_id = g.id, updated_at = now() where user_id = auth.uid();
  perform securelink.log('member.joined', 'agency', g.id::text, jsonb_build_object('role', inv.grants_role, 'invite', inv.id));
  return jsonb_build_object('agency', g.name, 'role', inv.grants_role);
end $$;

create function securelink.require_responder()
returns securelink.members language plpgsql security definer set search_path = '' as $$
declare m securelink.members;
begin
  m := securelink.me();
  if m.role not in ('responder','agency_admin') or m.agency_id is null
     or not exists (select 1 from securelink.agencies where id = m.agency_id and status = 'active') then
    raise exception 'Responder access only' using errcode = '42501';
  end if;
  return m;
end $$;

-- Open alerts routed to my agency, nearest first. Responders get precise location: they need it to respond.
create function public.securelink_queue()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members;
begin
  m := securelink.require_responder();
  return (select coalesce(jsonb_agg(x order by x->>'status' = 'acknowledged', (x->>'distanceKm')::numeric nulls last), '[]') from (
    select securelink.summary(i) || jsonb_build_object('lat', i.lat, 'lng', i.lng, 'accuracy', i.accuracy_m, 'lastSeenAt', i.last_seen_at,
      'distanceKm', r.distance_km, 'mine', i.acknowledged_by = auth.uid(), 'takenByUs', i.agency_id = m.agency_id, 'note', i.note) as x
    from securelink.incident_routes r join securelink.incidents i on i.id = r.incident_id
    where r.agency_id = m.agency_id and (i.status = 'active' or (i.status = 'acknowledged' and i.agency_id = m.agency_id))
    order by i.started_at desc limit 200) q);
end $$;

-- Full detail of one incident: responders of a routed agency, or a platform admin holding break-glass.
create function public.securelink_incident(p_incident uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members; inc securelink.incidents; g uuid; u auth.users;
begin
  m := securelink.me();
  select * into inc from securelink.incidents where id = p_incident;
  if inc.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if not securelink.responder_for(inc.id) then
    g := securelink.grant_for(inc.id);
    if g is null then raise exception 'Not found' using errcode = 'P0002'; end if;
    update securelink.breakglass set use_count = use_count + 1 where id = g;
    perform securelink.log('incident.read', 'incident', inc.id::text, jsonb_build_object('grant', g));
  end if;
  select * into u from auth.users where id = inc.user_id;
  return securelink.summary(inc) || jsonb_build_object(
    'lat', inc.lat, 'lng', inc.lng, 'accuracy', inc.accuracy_m, 'lastSeenAt', inc.last_seen_at, 'note', inc.note, 'outcome', inc.outcome,
    'person', jsonb_build_object('name', coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), 'SecureLink user'), 'phone', u.phone),
    'trail', (select coalesce(jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'accuracy', accuracy_m, 'at', at) order by at), '[]')
              from (select * from securelink.incident_points where incident_id = inc.id order by at desc limit 500) p),
    'audio', (select coalesce(jsonb_agg(jsonb_build_object('path', path, 'seconds', seconds, 'at', at) order by at), '[]') from securelink.incident_audio where incident_id = inc.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'agency', ag.name) order by e.at), '[]')
               from securelink.incident_events e left join securelink.agencies ag on ag.id = e.agency_id where e.incident_id = inc.id));
end $$;

create function public.securelink_acknowledge(p_incident uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members; inc securelink.incidents;
begin
  m := securelink.require_responder();
  if not securelink.responder_for(p_incident) then raise exception 'Not found' using errcode = 'P0002'; end if;
  update securelink.incidents set status = 'acknowledged', acknowledged_at = now(), acknowledged_by = auth.uid(), agency_id = m.agency_id
    where id = p_incident and status = 'active' returning * into inc;
  if inc.id is null then
    select * into inc from securelink.incidents where id = p_incident;
    raise exception '%', case when inc.status = 'acknowledged' then 'Another responder already took this alert' else 'This alert is closed' end using errcode = '22023';
  end if;
  insert into securelink.incident_events (incident_id, kind, actor, agency_id) values (inc.id, 'acknowledged', auth.uid(), m.agency_id);
  perform securelink.notify('sl:user:' || inc.user_id, 'incident', securelink.summary(inc));
  perform securelink.notify('sl:agency:' || r.agency_id, 'incident', securelink.summary(inc)) from securelink.incident_routes r where r.incident_id = inc.id;
  perform securelink.notify('sl:ops', 'incident', securelink.summary(inc));
  return securelink.summary(inc);
end $$;

create function public.securelink_resolve(p_incident uuid, p_outcome text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members; inc securelink.incidents;
begin
  m := securelink.require_responder();
  if coalesce(length(trim(p_outcome)), 0) < 3 then raise exception 'Say briefly what happened' using errcode = '22023'; end if;
  update securelink.incidents set status = 'resolved', closed_at = now(), resolved_by = auth.uid(), outcome = left(trim(p_outcome), 500),
      agency_id = coalesce(agency_id, m.agency_id)
    where id = p_incident and status in ('active','acknowledged') and (agency_id = m.agency_id or (agency_id is null and securelink.responder_for(p_incident)))
    returning * into inc;
  if inc.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  insert into securelink.incident_events (incident_id, kind, actor, agency_id, detail) values (inc.id, 'resolved', auth.uid(), m.agency_id, jsonb_build_object('outcome', inc.outcome));
  perform securelink.notify('sl:user:' || inc.user_id, 'incident', securelink.summary(inc));
  perform securelink.notify('sl:agency:' || r.agency_id, 'incident', securelink.summary(inc)) from securelink.incident_routes r where r.incident_id = inc.id;
  perform securelink.notify('sl:ops', 'incident', securelink.summary(inc));
  return securelink.summary(inc);
end $$;

create function public.securelink_agency_members()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members;
begin
  m := securelink.require_responder();
  if m.role <> 'agency_admin' then raise exception 'Agency admins only' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), split_part(u.email, '@', 1)),
            'email', u.email, 'role', x.role, 'status', x.status, 'since', x.updated_at) order by x.updated_at), '[]')
          from securelink.members x join auth.users u on u.id = x.user_id where x.agency_id = m.agency_id and x.role in ('responder','agency_admin'));
end $$;

-- ---------------------------------------------------------------------------------------------
-- Operator portal API (platform_admin only; everything else gets "Not found")
-- ---------------------------------------------------------------------------------------------
create function public.securelink_portal_overview()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return jsonb_build_object(
    'users', (select count(*) from securelink.members),
    'responders', (select count(*) from securelink.members where role in ('responder','agency_admin') and status = 'active'),
    'agencies', (select count(*) from securelink.agencies where status = 'active'),
    'activeAlerts', (select count(*) from securelink.incidents where status in ('active','acknowledged')),
    'todayAlerts', (select count(*) from securelink.incidents where started_at > now() - interval '24 hours'),
    'unroutedOpen', (select count(*) from securelink.incidents where status = 'active' and unrouted),
    'signalLostOpen', (select count(*) from securelink.incidents where status in ('active','acknowledged') and signal_lost_at is not null),
    'blindAlerts', jsonb_build_object('allTime', (select count(*) from securelink.incidents where lat is null and started_at < now() - interval '2 minutes'),
                                      'today', (select count(*) from securelink.incidents where lat is null and started_at > now() - interval '24 hours')),
    'byCategory', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'count', n) order by n desc), '[]')
                   from (select category, count(*) n from securelink.incidents where started_at > now() - interval '30 days' group by 1) c),
    'byAgency', (select coalesce(jsonb_agg(jsonb_build_object('agency', name, 'kinds', kinds, 'count', n) order by n desc), '[]')
                 from (select g.name, g.kinds, count(i.id) n from securelink.agencies g left join securelink.incidents i on i.agency_id = g.id and i.started_at > now() - interval '30 days'
                       group by g.id) a),
    'byState', (select coalesce(jsonb_agg(jsonb_build_object('state', st, 'count', n) order by n desc), '[]')
                from (select coalesce(nullif(g.states[1], ''), 'Unassigned') st, count(*) n from securelink.incidents i left join securelink.agencies g on g.id = i.agency_id
                      where i.started_at > now() - interval '30 days' group by 1) s));
end $$;

create function public.securelink_portal_metrics(p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d integer := least(greatest(coalesce(p_days, 7), 1), 365); r jsonb;
begin
  perform securelink.require_admin();
  with w as (select * from securelink.incidents where started_at > now() - make_interval(days => d) and status <> 'cancelled'),
  ack as (select extract(epoch from acknowledged_at - started_at)::int s from w where acknowledged_at is not null),
  res as (select extract(epoch from closed_at - started_at)::int s from w where status = 'resolved')
  select jsonb_build_object('windowDays', d, 'total', (select count(*) from w),
    'acknowledged', (select count(*) from ack),
    'ackRate', coalesce(round(100.0 * (select count(*) from ack) / nullif((select count(*) from w), 0)), 0),
    'ackSeconds', jsonb_build_object('n', (select count(*) from ack),
      'median', (select percentile_disc(0.5) within group (order by s) from ack), 'p90', (select percentile_disc(0.9) within group (order by s) from ack)),
    'escalated', (select count(*) from w where escalations > 0),
    'escalationRate', coalesce(round(100.0 * (select count(*) from w where escalations > 0) / nullif((select count(*) from w), 0)), 0),
    'resolved', (select count(*) from res),
    'resolveRate', coalesce(round(100.0 * (select count(*) from res) / nullif((select count(*) from w), 0)), 0),
    'resolutionSeconds', jsonb_build_object('n', (select count(*) from res), 'median', (select percentile_disc(0.5) within group (order by s) from res)),
    'blindAlerts', (select count(*) from w where lat is null),
    'blindRate', coalesce(round(100.0 * (select count(*) from w where lat is null) / nullif((select count(*) from w), 0)), 0),
    'unrouted', (select count(*) from w where unrouted)) into r;
  return r;
end $$;

-- Metadata only: no person, no precise location (rounded to ~11 km), unless break-glass is used separately.
create function public.securelink_portal_incidents(p_status text default null, p_category text default null, p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return (select coalesce(jsonb_agg(securelink.summary(i) || jsonb_build_object('area', case when i.lat is null then null else round(i.lat::numeric, 1)::text || ', ' || round(i.lng::numeric, 1)::text end,
            'state', (select g.states[1] from securelink.agencies g where g.id = i.agency_id), 'routedTo', (select count(*) from securelink.incident_routes r where r.incident_id = i.id))
          order by i.started_at desc), '[]')
    from (select * from securelink.incidents
          where (p_status is null or p_status = '' or status = p_status or (p_status = 'open' and status in ('active','acknowledged')))
            and (p_category is null or p_category = '' or category = p_category)
          order by started_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) i);
end $$;

create function public.securelink_portal_agencies()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return (select coalesce(jsonb_agg(to_jsonb(g) - 'created_by' || jsonb_build_object('responderCount',
            (select count(*) from securelink.members m where m.agency_id = g.id and m.role in ('responder','agency_admin') and m.status = 'active')) order by g.created_at desc), '[]')
          from securelink.agencies g);
end $$;

create function public.securelink_portal_create_agency(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g securelink.agencies;
begin
  perform securelink.require_admin();
  insert into securelink.agencies (name, kinds, command, states, base_lat, base_lng, radius_km, contact_name, contact_phone, contact_email, seat_limit, created_by)
  values (trim(p->>'name'), array(select jsonb_array_elements_text(p->'kinds')), nullif(trim(coalesce(p->>'command', '')), ''),
          coalesce(array(select jsonb_array_elements_text(p->'states')), '{}'), (p->>'baseLat')::double precision, (p->>'baseLng')::double precision,
          coalesce((p->>'radiusKm')::integer, 25), nullif(trim(coalesce(p->>'contactName', '')), ''), nullif(trim(coalesce(p->>'contactPhone', '')), ''),
          nullif(lower(trim(coalesce(p->>'contactEmail', ''))), ''), coalesce((p->>'seatLimit')::integer, 50), auth.uid())
  returning * into g;
  perform securelink.log('agency.created', 'agency', g.id::text, jsonb_build_object('name', g.name, 'kinds', g.kinds));
  return to_jsonb(g) - 'created_by';
exception when check_violation or not_null_violation or invalid_text_representation then
  raise exception 'Check the agency details: name, at least one service type, base location and radius are required' using errcode = '22023';
end $$;

create function public.securelink_portal_set_agency_status(p_agency uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g securelink.agencies;
begin
  perform securelink.require_admin();
  update securelink.agencies set status = p_status where id = p_agency and p_status in ('active','suspended') returning * into g;
  if g.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  perform securelink.log('agency.' || p_status, 'agency', g.id::text, jsonb_build_object('name', g.name));
  return to_jsonb(g) - 'created_by';
end $$;

create function public.securelink_portal_invites()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'codeHint', i.code_hint, 'agency', jsonb_build_object('id', g.id, 'name', g.name),
            'grantsRole', i.grants_role, 'maxUses', i.max_uses, 'useCount', i.use_count, 'expiresAt', i.expires_at, 'revokedAt', i.revoked_at, 'createdAt', i.created_at,
            'status', case when i.revoked_at is not null then 'revoked' when i.expires_at <= now() then 'expired' when i.use_count >= i.max_uses then 'used' else 'active' end)
          order by i.created_at desc), '[]')
          from securelink.invites i join securelink.agencies g on g.id = i.agency_id);
end $$;

-- The plaintext code is returned once, here; only its hash is stored.
create function public.securelink_portal_issue_invite(p_agency uuid, p_role text default 'responder', p_max_uses integer default 1, p_days integer default 7)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare code text; inv securelink.invites; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea; k integer;
begin
  perform securelink.require_admin();
  if not exists (select 1 from securelink.agencies where id = p_agency) then raise exception 'Not found' using errcode = 'P0002'; end if;
  b := extensions.gen_random_bytes(12); code := '';
  for k in 0..11 loop code := code || substr(alphabet, (get_byte(b, k) % 32) + 1, 1); end loop;
  insert into securelink.invites (code_hash, code_hint, agency_id, grants_role, max_uses, expires_at, created_by)
  values (encode(extensions.digest(code, 'sha256'), 'hex'), right(code, 4), p_agency, coalesce(nullif(p_role, ''), 'responder'),
          least(greatest(coalesce(p_max_uses, 1), 1), 500), now() + make_interval(days => least(greatest(coalesce(p_days, 7), 1), 90)), auth.uid())
  returning * into inv;
  perform securelink.log('invite.issued', 'invite', inv.id::text, jsonb_build_object('agency', p_agency, 'role', inv.grants_role, 'maxUses', inv.max_uses));
  return jsonb_build_object('code', substr(code, 1, 4) || '-' || substr(code, 5, 4) || '-' || substr(code, 9, 4), 'invite', jsonb_build_object('id', inv.id, 'expiresAt', inv.expires_at));
end $$;

create function public.securelink_portal_revoke_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  update securelink.invites set revoked_at = now() where id = p_invite and revoked_at is null;
  if not found then raise exception 'Not found' using errcode = 'P0002'; end if;
  perform securelink.log('invite.revoked', 'invite', p_invite::text);
end $$;

create function public.securelink_portal_accounts(p_role text default null, p_search text default null, p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return (select coalesce(jsonb_agg(x order by x->>'since' desc), '[]') from (
    select jsonb_build_object('id', m.user_id, 'name', coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), split_part(u.email, '@', 1)), 'email', u.email,
             'role', m.role, 'status', m.status, 'agency', (select jsonb_build_object('id', g.id, 'name', g.name) from securelink.agencies g where g.id = m.agency_id),
             'since', m.created_at) x
    from securelink.members m join auth.users u on u.id = m.user_id
    where (p_role is null or p_role = '' or m.role = p_role)
      and (p_search is null or p_search = '' or u.email ilike '%' || p_search || '%' or u.raw_user_meta_data->>'full_name' ilike '%' || p_search || '%')
    order by m.created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) q);
end $$;

create function public.securelink_portal_update_account(p_user uuid, p_role text default null, p_status text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m securelink.members;
begin
  perform securelink.require_admin();
  if p_user = auth.uid() then raise exception 'You cannot change your own account here' using errcode = '22023'; end if;
  if p_role is not null and p_role not in ('citizen','responder','agency_admin','platform_admin') then raise exception 'Unknown role' using errcode = '22023'; end if;
  if p_status is not null and p_status not in ('active','suspended') then raise exception 'Unknown status' using errcode = '22023'; end if;
  update securelink.members set role = coalesce(p_role, role), status = coalesce(p_status, status),
      agency_id = case when coalesce(p_role, role) in ('citizen','platform_admin') then null else agency_id end, updated_at = now()
    where user_id = p_user returning * into m;
  if m.user_id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  perform securelink.log('account.updated', 'account', p_user::text, jsonb_build_object('role', p_role, 'status', p_status));
  return jsonb_build_object('id', m.user_id, 'role', m.role, 'status', m.status);
exception when check_violation then
  raise exception 'Responders need an agency: invite them with a code instead' using errcode = '22023';
end $$;

create function public.securelink_portal_breakglass()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'incidentId', b.incident_id, 'reason', b.reason, 'operator', u.email,
            'expiresAt', b.expires_at, 'revokedAt', b.revoked_at, 'useCount', b.use_count, 'createdAt', b.created_at,
            'live', b.revoked_at is null and b.expires_at > now()) order by b.created_at desc), '[]')
          from securelink.breakglass b join auth.users u on u.id = b.operator);
end $$;

create function public.securelink_portal_open_breakglass(p_incident uuid, p_reason text, p_minutes integer default 30)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b securelink.breakglass;
begin
  perform securelink.require_admin();
  if not exists (select 1 from securelink.incidents where id = p_incident) then raise exception 'Not found' using errcode = 'P0002'; end if;
  if coalesce(length(trim(p_reason)), 0) < 10 then raise exception 'Write the reason in a sentence (at least 10 characters)' using errcode = '22023'; end if;
  insert into securelink.breakglass (incident_id, operator, reason, expires_at)
    values (p_incident, auth.uid(), trim(p_reason), now() + make_interval(mins => least(greatest(coalesce(p_minutes, 30), 5), 240)))
    returning * into b;
  perform securelink.log('breakglass.opened', 'incident', p_incident::text, jsonb_build_object('grant', b.id, 'reason', b.reason, 'expiresAt', b.expires_at));
  return jsonb_build_object('id', b.id, 'expiresAt', b.expires_at);
end $$;

create function public.securelink_portal_revoke_breakglass(p_grant uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  update securelink.breakglass set revoked_at = now() where id = p_grant and revoked_at is null;
  if not found then raise exception 'Not found' using errcode = 'P0002'; end if;
  perform securelink.log('breakglass.revoked', 'breakglass', p_grant::text);
end $$;

create function public.securelink_portal_audit(p_limit integer default 200, p_action text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform securelink.require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'actor', u.email, 'action', a.action, 'targetType', a.target_type, 'targetId', a.target_id,
            'detail', a.detail, 'at', a.at) order by a.at desc), '[]')
          from (select * from securelink.audit where p_action is null or p_action = '' or action like p_action || '%' order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) a
          left join auth.users u on u.id = a.actor);
end $$;

-- ---------------------------------------------------------------------------------------------
-- Escalation and dead-man's switch: runs every 30 seconds.
-- ---------------------------------------------------------------------------------------------
create function securelink.tick()
returns void language plpgsql security definer set search_path = '' as $$
declare i securelink.incidents; n integer;
begin
  -- Unacknowledged past 2 minutes (then every 2 minutes, up to 3 times): widen and re-send.
  for i in select * from securelink.incidents where status = 'active' and escalations < 3
      and coalesce(escalated_at, started_at) < now() - interval '2 minutes' loop
    update securelink.incidents set escalations = escalations + 1, escalated_at = now() where id = i.id returning * into i;
    n := securelink.route(i.id);
    if n > 0 and i.unrouted then update securelink.incidents set unrouted = false where id = i.id; end if;
    insert into securelink.incident_events (incident_id, kind, detail) values (i.id, 'escalated', jsonb_build_object('level', i.escalations, 'newAgencies', n));
    -- Re-page agencies already routed so the alert is seen again.
    perform securelink.notify('sl:agency:' || r.agency_id, 'escalated', securelink.summary(i)) from securelink.incident_routes r where r.incident_id = i.id;
    perform securelink.notify('sl:ops', 'escalated', securelink.summary(i));
  end loop;
  -- Phone silent for 3 minutes: flag it; never close it.
  for i in select * from securelink.incidents where status in ('active','acknowledged') and signal_lost_at is null and last_seen_at < now() - interval '3 minutes' loop
    update securelink.incidents set signal_lost_at = now() where id = i.id returning * into i;
    insert into securelink.incident_events (incident_id, kind, detail) values (i.id, 'signal_lost', jsonb_build_object('lastSeenAt', i.last_seen_at));
    perform securelink.notify('sl:agency:' || r.agency_id, 'signal_lost', securelink.summary(i)) from securelink.incident_routes r where r.incident_id = i.id;
    perform securelink.notify('sl:ops', 'signal_lost', securelink.summary(i));
  end loop;
  delete from securelink.rate where at < now() - interval '2 hours';
end $$;

select cron.schedule('securelink-tick', '30 seconds', 'select securelink.tick()');

-- ---------------------------------------------------------------------------------------------
-- Realtime: who may listen to which channel
-- ---------------------------------------------------------------------------------------------
create function securelink.can_listen(p_topic text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_topic like 'sl:area:%'
    or p_topic = 'sl:user:' || auth.uid()::text
    or exists (select 1 from securelink.members m join securelink.agencies g on g.id = m.agency_id and g.status = 'active'
               where m.user_id = auth.uid() and m.status = 'active' and m.role in ('responder','agency_admin')
                 and p_topic = 'sl:agency:' || m.agency_id::text)
    or (p_topic = 'sl:ops' and exists (select 1 from securelink.members m where m.user_id = auth.uid() and m.role = 'platform_admin' and m.status = 'active'));
$$;

create policy securelink_receive on realtime.messages for select to authenticated
  using (extension = 'broadcast' and (select realtime.topic()) like 'sl:%' and securelink.can_listen((select realtime.topic())));

-- ---------------------------------------------------------------------------------------------
-- Audio storage: private bucket; path <incident id>/<random>.<ext>
-- ---------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('securelink-audio', 'securelink-audio', false, 10485760, array['audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/x-m4a'])
on conflict (id) do nothing;

create function securelink.can_upload_audio(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from securelink.incidents i where i.id::text = split_part(p_name, '/', 1)
                 and i.user_id = auth.uid() and i.status in ('active','acknowledged'));
$$;
create function securelink.can_read_audio(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare inc uuid;
begin
  begin inc := split_part(p_name, '/', 1)::uuid; exception when others then return false; end;
  return exists (select 1 from securelink.incidents where id = inc and user_id = auth.uid())
      or securelink.responder_for(inc) or securelink.grant_for(inc) is not null;
end $$;

create policy securelink_audio_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'securelink-audio' and securelink.can_upload_audio(name));
create policy securelink_audio_read on storage.objects for select to authenticated
  using (bucket_id = 'securelink-audio' and securelink.can_read_audio(name));

-- ---------------------------------------------------------------------------------------------
-- Permissions: only signed-in people may call the API; helpers are internal.
-- ---------------------------------------------------------------------------------------------
grant usage on schema securelink to authenticated;  -- for the storage/realtime policy helpers only
revoke execute on all functions in schema securelink from public, anon, authenticated;
grant execute on function securelink.can_upload_audio(text), securelink.can_read_audio(text), securelink.can_listen(text) to authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'securelink\_%' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
