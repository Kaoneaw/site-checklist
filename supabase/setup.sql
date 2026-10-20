-- Run once in the SQL Editor of your own Supabase project.
-- One project snapshot per authenticated account; no data is seeded here.
begin;

create table if not exists public.site_checklist_projects (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null,
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now(),
  constraint site_checklist_payload_valid check (
    jsonb_typeof(payload) = 'object'
    and payload ?& array['version','project','units','tasks','templates','demo']
    and jsonb_typeof(payload->'version') = 'number'
    and payload->>'version' = '1'
    and jsonb_typeof(payload->'project') = 'string'
    and jsonb_typeof(payload->'units') = 'array'
    and jsonb_typeof(payload->'tasks') = 'array'
    and jsonb_typeof(payload->'templates') = 'array'
    and jsonb_typeof(payload->'demo') = 'boolean'
    and octet_length(payload::text) <= 20971520
  )
);

alter table public.site_checklist_projects enable row level security;
revoke all on public.site_checklist_projects from anon, authenticated;
grant select on public.site_checklist_projects to authenticated;

drop policy if exists site_checklist_read_own on public.site_checklist_projects;
create policy site_checklist_read_own on public.site_checklist_projects
  for select to authenticated using ((select auth.uid()) = user_id);

-- Only this RPC can write. SECURITY DEFINER uses a fixed empty search path,
-- a trusted auth.uid(), and fully qualified table references; client input
-- never chooses the owner. The revision comparison is atomic in PostgreSQL.
create or replace function public.save_site_checklist_project(
  expected_revision bigint,
  snapshot jsonb
) returns table(revision bigint, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
begin
  if owner_id is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;
  if snapshot is null or jsonb_typeof(snapshot) <> 'object' then
    raise exception using errcode = '22023', message = 'Invalid project snapshot';
  end if;
  if expected_revision is null then
    return query
      insert into public.site_checklist_projects as p (user_id, payload)
      values (owner_id, snapshot)
      on conflict (user_id) do nothing
      returning p.revision, p.updated_at;
  else
    if expected_revision < 1 then
      raise exception using errcode = '22023', message = 'Invalid revision';
    end if;
    return query
      update public.site_checklist_projects as p
      set payload = snapshot, revision = p.revision + 1, updated_at = clock_timestamp()
      where p.user_id = owner_id and p.revision = expected_revision
      returning p.revision, p.updated_at;
  end if;
  if not found then
    raise exception using errcode = 'PT409', message = 'Newer online version exists. Load it before saving.';
  end if;
end;
$$;

revoke all on function public.save_site_checklist_project(bigint, jsonb) from public, anon;
grant execute on function public.save_site_checklist_project(bigint, jsonb) to authenticated;
commit;
