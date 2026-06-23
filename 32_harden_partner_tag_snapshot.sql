-- 32_harden_partner_tag_snapshot.sql — (2026-06-22) harden the outage tag join
-- (get_network_partner_tags) against a truncated/partial nightly snapshot.
--
-- BUG (latent): the function read both inputs at max(report_date) — the NEWEST
-- snapshot, unconditionally. Retention's prune_ie_table_to_latest (schema/10) has an
-- 80% partial-load guard: when a nightly snapshot lands < 80% of the largest on hand
-- (a stalled ~3.44M-row partner_account_tag load, or a thin ie_eeros load) it SKIPS
-- pruning and KEEPS the older full snapshot. The read-path and retention then disagree
-- on which snapshot is authoritative: retention preserves the old good one, but the
-- read jumps to the truncated newest max() → tag coverage collapses even though a full
-- snapshot is still on hand, ignored. (Confirmed clean in the live DB 2026-06-22 — a
-- single full snapshot on both sides — but a partial newer load would surface it.)
--
-- FIX: read each input at its MOST-POPULATED recent report_date (ties → newest),
-- mirroring the retention guard, so a truncated newest snapshot can't be authoritative.
-- Cheap at latest-only retention (1-2 dates on hand). Idempotent CREATE OR REPLACE —
-- identical to canonical ocp/schema/17. Run as `vantage` on `eero_vantage`. The
-- outage-worker calls this over pg (NOT PostgREST) → no `notify pgrst`.

CREATE OR REPLACE FUNCTION public.get_network_partner_tags(p_network_ids text[])
 RETURNS TABLE(network_id text, partner_account_id text, tag_names text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_eeros_date date;
  v_tags_date  date;
BEGIN
  -- Authoritative snapshot = most-populated report_date on hand (ties → newest),
  -- NOT max() — so a partial/truncated newest load can't be read as authoritative
  -- and collapse coverage (retention's 80% guard preserves the older full snapshot).
  SELECT report_date INTO v_eeros_date
  FROM public.ie_eeros
  GROUP BY report_date
  ORDER BY count(*) DESC, report_date DESC
  LIMIT 1;

  SELECT report_date INTO v_tags_date
  FROM public.ie_partner_account_tags
  GROUP BY report_date
  ORDER BY count(*) DESC, report_date DESC
  LIMIT 1;

  RETURN QUERY
  WITH net AS (
    SELECT e.network_id, min(e.customer_account_id) AS pid
    FROM public.ie_eeros e
    WHERE e.network_id = any(p_network_ids)
      AND e.customer_account_id IS NOT NULL
      AND e.report_date = v_eeros_date
    GROUP BY e.network_id
  ),
  tags AS (
    SELECT t.partner_account_id AS pid, array_agg(DISTINCT t.tag_name) AS tag_names
    FROM public.ie_partner_account_tags t
    WHERE t.report_date = v_tags_date
      AND t.partner_account_id IN (SELECT pid FROM net)
      AND t.tag_name IS NOT NULL
    GROUP BY t.partner_account_id
  )
  SELECT n.network_id,
         n.pid AS partner_account_id,
         COALESCE(tg.tag_names, '{}'::text[]) AS tag_names
  FROM net n
  LEFT JOIN tags tg ON tg.pid = n.pid;
END;
$function$;

grant execute on function public.get_network_partner_tags(text[]) to authenticated;
