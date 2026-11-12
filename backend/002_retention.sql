-- SecureLink retention (privacy policy: alerts 12 months, audit log 2 years).
-- Applied as migration securelink_4_retention. The daily job calls the securelink-retention edge
-- function, which removes expired audio from storage and then calls securelink_retention_purge().

create or replace function public.securelink_retention_paths(p_limit integer default 500)
 returns setof text language sql stable security definer set search_path to ''
as $$
  select a.path from securelink.incident_audio a join securelink.incidents i on i.id = a.incident_id
  where i.closed_at < now() - interval '12 months' limit least(greatest(p_limit, 1), 1000);
$$;

create or replace function public.securelink_retention_purge()
 returns jsonb language plpgsql security definer set search_path to ''
as $$
declare n_inc integer; n_audit integer;
begin
  -- Only incidents whose audio is already gone from storage (the function removes it first).
  delete from securelink.incidents i where i.closed_at < now() - interval '12 months'
    and not exists (select 1 from storage.objects o join securelink.incident_audio a on a.path = o.name
                    where o.bucket_id = 'securelink-audio' and a.incident_id = i.id);
  get diagnostics n_inc = row_count;
  delete from securelink.audit where at < now() - interval '2 years';
  get diagnostics n_audit = row_count;
  delete from securelink.breakglass where expires_at < now() - interval '2 years';
  return jsonb_build_object('incidents', n_inc, 'audit', n_audit);
end $$;

revoke all on function public.securelink_retention_paths(integer) from public, anon, authenticated;
revoke all on function public.securelink_retention_purge() from public, anon, authenticated;
grant execute on function public.securelink_retention_paths(integer) to service_role;
grant execute on function public.securelink_retention_purge() to service_role;

select cron.schedule('securelink-retention', '17 2 * * *', $c$
  select net.http_post('https://atgqjrmcvpctywklfigb.supabase.co/functions/v1/securelink-retention', '{}'::jsonb,
    headers := '{"content-type":"application/json"}'::jsonb, timeout_milliseconds := 60000)
$c$);
