-- =====================================================================
-- Baseball manager: esquema de Supabase
-- Cómo usarlo: Supabase > SQL Editor > New query > pega TODO > Run
-- Se puede ejecutar más de una vez sin romper nada.
--
-- Permisos (lo que pediste):
--  * Todos los usuarios registrados tienen los mismos permisos.
--  * Quien crea un equipo es su manager y es el único que puede modificarlo
--    (equipo, jugadores, juegos, jugadas, estadísticas).
--  * Quien es invitado a un equipo entra como jugador y solo puede ver.
-- =====================================================================

-- ---------- Tablas ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  logo_path text,                         -- ruta dentro del bucket "team-logos"
  created_at timestamptz not null default now()
);

create table if not exists public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('manager','player')),
  created_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  user_id uuid references auth.users(id) on delete set null,   -- cuenta vinculada (opcional)
  created_at timestamptz not null default now()
);
create unique index if not exists players_team_name_uq on public.players (team_id, lower(name));

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  email text not null,
  status text not null default 'pending' check (status in ('pending','accepted','revoked')),
  invited_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);
create unique index if not exists invitations_pending_uq on public.invitations (team_id, lower(email)) where status = 'pending';

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  rival text not null check (char_length(rival) between 1 and 60),
  played_on date not null default current_date,
  status text not null default 'live' check (status in ('live','final')),
  lineup jsonb not null default '[]',      -- orden al bat (máx. 12)
  subs jsonb not null default '[]',        -- cambios
  runs_for int not null default 0,
  runs_against int not null default 0,
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);

-- Cada jugada es un evento (hit, doble, out de corredor, etc.). Deshacer = borrar el último.
create table if not exists public.game_events (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games(id) on delete cascade,
  seq int not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  unique (game_id, seq)
);

-- Estadísticas finales por jugador y partido (se llena al guardar el partido)
create table if not exists public.game_player_stats (
  game_id uuid not null references public.games(id) on delete cascade,
  player_name text not null,
  player_id uuid references public.players(id) on delete set null,
  ab int not null default 0,   -- veces al bat
  h  int not null default 0,   -- hits
  d  int not null default 0,   -- dobles
  t  int not null default 0,   -- triples
  hr int not null default 0,   -- home runs
  rbi int not null default 0,  -- carreras impulsadas
  r  int not null default 0,   -- carreras anotadas
  bb int not null default 0,   -- bases por bolas
  k  int not null default 0,   -- ponches
  sf int not null default 0,   -- fly de sacrificio
  fc int not null default 0,   -- fielder's choice
  dp int not null default 0,   -- doble play
  ob int not null default 0,   -- outs de corredor en bases
  primary key (game_id, player_name)
);

create index if not exists games_team_idx on public.games (team_id, played_on desc);
create index if not exists players_team_idx on public.players (team_id);
create index if not exists members_user_idx on public.team_members (user_id);

-- ---------- Funciones de apoyo (security definer evita recursión en RLS) ----------
create or replace function public.is_team_member(tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_members where team_id = tid and user_id = auth.uid());
$$;

create or replace function public.is_team_manager(tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_members where team_id = tid and user_id = auth.uid() and role = 'manager');
$$;

create or replace function public.is_game_member(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.games g where g.id = gid and public.is_team_member(g.team_id));
$$;

create or replace function public.is_game_manager(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.games g where g.id = gid and public.is_team_manager(g.team_id));
$$;

-- ---------- Triggers ----------
-- Al registrarse un usuario se crea su perfil (toma el nombre de los metadatos de signup)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Al crear un equipo, quien lo crea queda como manager
create or replace function public.add_owner_as_manager() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.team_members (team_id, user_id, role)
  values (new.id, new.owner_id, 'manager')
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_team_created on public.teams;
create trigger on_team_created after insert on public.teams
  for each row execute function public.add_owner_as_manager();

-- Aceptar una invitación: el invitado entra al equipo como jugador (solo lectura)
create or replace function public.accept_invitation(inv uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invitations%rowtype;
begin
  select * into i from public.invitations
   where id = inv and status = 'pending'
     and lower(email) = lower(coalesce(auth.jwt()->>'email', ''));
  if not found then
    raise exception 'Invitación no válida o ya usada';
  end if;
  insert into public.team_members (team_id, user_id, role)
  values (i.team_id, auth.uid(), 'player') on conflict do nothing;
  update public.invitations set status = 'accepted' where id = inv;
end $$;
revoke all on function public.accept_invitation(uuid) from public, anon;
grant execute on function public.accept_invitation(uuid) to authenticated;

-- ---------- Seguridad por filas (RLS) ----------
alter table public.profiles          enable row level security;
alter table public.teams             enable row level security;
alter table public.team_members      enable row level security;
alter table public.players           enable row level security;
alter table public.invitations       enable row level security;
alter table public.games             enable row level security;
alter table public.game_events       enable row level security;
alter table public.game_player_stats enable row level security;

-- profiles: ves tu perfil y el de quienes comparten equipo contigo
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  id = auth.uid() or exists (
    select 1 from public.team_members a join public.team_members b on a.team_id = b.team_id
    where a.user_id = auth.uid() and b.user_id = profiles.id)
);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- teams
drop policy if exists teams_select on public.teams;
create policy teams_select on public.teams for select to authenticated
  using (owner_id = auth.uid() or public.is_team_member(id));
drop policy if exists teams_insert on public.teams;
create policy teams_insert on public.teams for insert to authenticated
  with check (owner_id = auth.uid());
drop policy if exists teams_update on public.teams;
create policy teams_update on public.teams for update to authenticated
  using (public.is_team_manager(id)) with check (public.is_team_manager(id));
drop policy if exists teams_delete on public.teams;
create policy teams_delete on public.teams for delete to authenticated
  using (public.is_team_manager(id));

-- team_members
drop policy if exists members_select on public.team_members;
create policy members_select on public.team_members for select to authenticated
  using (user_id = auth.uid() or public.is_team_member(team_id));
drop policy if exists members_insert on public.team_members;
create policy members_insert on public.team_members for insert to authenticated
  with check (public.is_team_manager(team_id));
drop policy if exists members_update on public.team_members;
create policy members_update on public.team_members for update to authenticated
  using (public.is_team_manager(team_id)) with check (public.is_team_manager(team_id));
drop policy if exists members_delete on public.team_members;
create policy members_delete on public.team_members for delete to authenticated
  using (public.is_team_manager(team_id) or user_id = auth.uid());

-- players
drop policy if exists players_select on public.players;
create policy players_select on public.players for select to authenticated using (public.is_team_member(team_id));
drop policy if exists players_write on public.players;
create policy players_write on public.players for all to authenticated
  using (public.is_team_manager(team_id)) with check (public.is_team_manager(team_id));

-- invitations: las ve el manager del equipo y la persona invitada (por su correo)
drop policy if exists invitations_select on public.invitations;
create policy invitations_select on public.invitations for select to authenticated using (
  public.is_team_manager(team_id) or lower(email) = lower(coalesce(auth.jwt()->>'email', '')));
drop policy if exists invitations_write on public.invitations;
create policy invitations_write on public.invitations for all to authenticated
  using (public.is_team_manager(team_id)) with check (public.is_team_manager(team_id));

-- games
drop policy if exists games_select on public.games;
create policy games_select on public.games for select to authenticated using (public.is_team_member(team_id));
drop policy if exists games_write on public.games;
create policy games_write on public.games for all to authenticated
  using (public.is_team_manager(team_id)) with check (public.is_team_manager(team_id));

-- game_events y game_player_stats
drop policy if exists events_select on public.game_events;
create policy events_select on public.game_events for select to authenticated using (public.is_game_member(game_id));
drop policy if exists events_write on public.game_events;
create policy events_write on public.game_events for all to authenticated
  using (public.is_game_manager(game_id)) with check (public.is_game_manager(game_id));

drop policy if exists stats_select on public.game_player_stats;
create policy stats_select on public.game_player_stats for select to authenticated using (public.is_game_member(game_id));
drop policy if exists stats_write on public.game_player_stats;
create policy stats_write on public.game_player_stats for all to authenticated
  using (public.is_game_manager(game_id)) with check (public.is_game_manager(game_id));

-- ---------- Totales por jugador (respeta RLS de quien consulta) ----------
create or replace view public.team_player_totals with (security_invoker = true) as
select g.team_id,
       s.player_name,
       count(*)::int                      as jj,
       sum(s.ab)::int  as ab,  sum(s.h)::int  as h,   sum(s.d)::int  as d,
       sum(s.t)::int   as t,   sum(s.hr)::int as hr,  sum(s.rbi)::int as rbi,
       sum(s.r)::int   as r,   sum(s.bb)::int as bb,  sum(s.k)::int  as k,
       sum(s.sf)::int  as sf,  sum(s.fc)::int as fc,  sum(s.dp)::int as dp,
       sum(s.ob)::int  as ob,
       case when sum(s.ab) > 0 then round(sum(s.h)::numeric / sum(s.ab), 3) else 0 end as avg
from public.game_player_stats s
join public.games g on g.id = s.game_id
where g.status = 'final'
group by g.team_id, s.player_name;
grant select on public.team_player_totals to authenticated;

-- ---------- Logos de equipos (Storage) ----------
-- Los archivos se guardan como  <team_id>/logo.jpg  ; solo el manager del equipo puede subirlos.
insert into storage.buckets (id, name, public)
values ('team-logos', 'team-logos', true)
on conflict (id) do nothing;

drop policy if exists "logos_insert" on storage.objects;
create policy "logos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-logos' and public.is_team_manager(((storage.foldername(name))[1])::uuid));
drop policy if exists "logos_update" on storage.objects;
create policy "logos_update" on storage.objects for update to authenticated
  using (bucket_id = 'team-logos' and public.is_team_manager(((storage.foldername(name))[1])::uuid));
drop policy if exists "logos_delete" on storage.objects;
create policy "logos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'team-logos' and public.is_team_manager(((storage.foldername(name))[1])::uuid));

-- ---------- Tiempo real (para que los jugadores vean el juego en vivo) ----------
do $$ begin alter publication supabase_realtime add table public.games; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime add table public.game_events; exception when others then null; end $$;
