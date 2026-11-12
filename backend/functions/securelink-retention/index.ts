// SecureLink retention (privacy policy): removes audio of alerts closed more than 12 months ago from
// storage, then purges those alerts and audit entries older than 2 years. Runs daily from pg_cron.
// It takes no input and returns only counts, and it can only ever delete data already past its
// retention date, so calling it more often changes nothing.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method" });
  let removed = 0;
  for (let round = 0; round < 20; round++) {
    const { data: paths, error } = await db.rpc("securelink_retention_paths", { p_limit: 500 });
    if (error) { console.error("retention paths", error.message); return json(500, { error: "paths" }); }
    const list = (paths ?? []) as string[];
    if (!list.length) break;
    const { error: rmError } = await db.storage.from("securelink-audio").remove(list);
    if (rmError) { console.error("retention remove", rmError.message); return json(500, { error: "remove" }); }
    removed += list.length;
    // Incidents whose audio is now gone are purged below; paths of those still waiting come back next round.
    const { error: purgeError } = await db.rpc("securelink_retention_purge");
    if (purgeError) { console.error("retention purge", purgeError.message); return json(500, { error: "purge" }); }
  }
  const { data, error } = await db.rpc("securelink_retention_purge");
  if (error) { console.error("retention purge", error.message); return json(500, { error: "purge" }); }
  return json(200, { audioRemoved: removed, ...(data as Record<string, number>) });
});
