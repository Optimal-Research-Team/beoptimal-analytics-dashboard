-- ============================================================================
-- beOptimal Clinic Analytics — Tier 1 Metabase Query Starter Library
-- Source: Supabase `public` schema  ·  Target: Metabase (native SQL questions)
-- Companion to PRD.md §3 (Tier 1 — Build Now). Metric numbers reference the PRD.
-- ============================================================================
--
-- CONVENTIONS (apply to every query — see PRD §2)
--   * Timezone:  always convert text timestamps before grouping by date:
--                (start_time::timestamptz AT TIME ZONE 'America/Toronto')
--                Raw start_time / end_time / created_at are TEXT, ISO-8601 UTC.
--   * Booked/attended filter:  lower(trim(status)) = 'active'
--                (defends against the dirty "cancelled\n" and the NULL row —
--                 never use status = 'active' raw).
--   * Longevity core = TWO service_ids: Longevity Membership Core + Enhanced Care.
--   * Visit duration comes from appointment_types.duration (minutes), never
--                end_time - start_time.
--   * Enrollment source of truth = user_service_enrollments (subscriptions /
--                subscription_items are deprecated).
--
-- ID REFERENCE (Appendix A)
--   service_id  Longevity Membership Core : 7ddbbc03-e7db-43b3-862d-edd991cd44df
--   service_id  Enhanced Care (legacy)    : 6272ba51-9041-4efa-8d85-3c99e48473e1
--   service_id  Women's Hormone Health    : f807683b-0aec-4643-90ed-1542debf542f
--
--   appt types  info session (admin)      : 8 (phone), 10 (video)
--   appt types  longevity intro           : 14 (phone), 2 (in-person), 13 (intro+intake)
--   appt types  menopause orientation     : 19 (admin) ; menopause info : 25
--   appt types  consumed-care (NP) visits : 1, 3, 6, 9, 11, 15, 18 (+ 20-24 NP-led)
--   appt types  EXCLUDED from consumed care: 2, 13, 14, 8, 10, 25, 19, 26
--
--   NP clinicians (clinicians.active = true):
--     Lisa Dufour      e00f4874-8a19-4d99-b814-095fe15b0c44
--     Tina (Ting Na) Xu 6b649c4f-5165-4069-a69c-cddeacfe309e
--     Chantelle Oostwoud 19d57efd-47fc-4726-a308-9b643179f68e
--     Lynne Penton     b39b692e-5476-44fe-b822-6df907a32a45
--     Edite Santos     80fbd86a-8897-41c4-827f-3505873a7bb8
--   Exclude pseudo-provider "Information Session": eaa2867e-54de-4b3c-a5fd-bda4a2a4fbb8
-- ============================================================================


-- ---------------------------------------------------------------------------
-- #3 — Active longevity core members  (distinct patients on core + legacy)
-- ---------------------------------------------------------------------------
SELECT count(DISTINCT user_id) AS active_longevity_members
FROM   user_service_enrollments
WHERE  status = 'active'
AND    service_id IN (
         '7ddbbc03-e7db-43b3-862d-edd991cd44df',  -- Longevity Membership Core
         '6272ba51-9041-4efa-8d85-3c99e48473e1'   -- Enhanced Care (legacy)
       );


-- ---------------------------------------------------------------------------
-- #9 — Active menopause foundation members
-- ---------------------------------------------------------------------------
SELECT count(DISTINCT user_id) AS active_menopause_members
FROM   user_service_enrollments
WHERE  status = 'active'
AND    service_id = 'f807683b-0aec-4643-90ed-1542debf542f';  -- Women's Hormone Health


-- ---------------------------------------------------------------------------
-- #13 — Total active across both programs  (distinct patients, deduped)
-- ---------------------------------------------------------------------------
SELECT
  count(DISTINCT user_id) FILTER (
    WHERE service_id IN (
      '7ddbbc03-e7db-43b3-862d-edd991cd44df',
      '6272ba51-9041-4efa-8d85-3c99e48473e1')) AS longevity,
  count(DISTINCT user_id) FILTER (
    WHERE service_id = 'f807683b-0aec-4643-90ed-1542debf542f') AS menopause,
  count(DISTINCT user_id)                       AS total_distinct_active
FROM user_service_enrollments
WHERE status = 'active';


-- ---------------------------------------------------------------------------
-- #1 — Week-over-week info sessions + intros (longevity funnel, top stages)
--      info 8/10 ; phone intro 14 ; in-person intro 2 ; intro+intake 13
-- ---------------------------------------------------------------------------
SELECT
  date_trunc('week', (a.start_time::timestamptz AT TIME ZONE 'America/Toronto'))::date AS week,
  count(*) FILTER (WHERE a.appointment_type_id IN (8, 10))      AS info_sessions,
  count(*) FILTER (WHERE a.appointment_type_id IN (2, 13, 14))  AS intros,
  count(*) FILTER (WHERE a.appointment_type_id = 14)            AS intro_phone,
  count(*) FILTER (WHERE a.appointment_type_id = 2)             AS intro_in_person,
  count(*) FILTER (WHERE a.appointment_type_id = 13)            AS intro_plus_intake
FROM   appointments a
WHERE  lower(trim(a.status)) = 'active'
AND    a.appointment_type_id IN (8, 10, 2, 13, 14)
GROUP  BY 1
ORDER  BY 1;


-- ---------------------------------------------------------------------------
-- #6 / 6.1-6.4 — Longevity funnel stages + stage-to-stage conversion
--      (trailing 8 weeks). Top stage = info sessions; final = paid registrations.
-- ---------------------------------------------------------------------------
WITH appt AS (
  SELECT
    count(*) FILTER (WHERE appointment_type_id IN (8, 10))     AS info_sessions,
    count(*) FILTER (WHERE appointment_type_id IN (2, 14))     AS intros_only,
    count(*) FILTER (WHERE appointment_type_id = 13)           AS intro_plus_intake
  FROM appointments
  WHERE lower(trim(status)) = 'active'
  AND   (start_time::timestamptz AT TIME ZONE 'America/Toronto') >= (now() AT TIME ZONE 'America/Toronto') - interval '8 weeks'
),
reg AS (
  SELECT count(DISTINCT user_id) AS paid_registrations
  FROM   user_service_enrollments
  WHERE  service_id IN ('7ddbbc03-e7db-43b3-862d-edd991cd44df','6272ba51-9041-4efa-8d85-3c99e48473e1')
  AND    start_date >= now() - interval '8 weeks'
  -- AND  payment_status = 'paid'   -- enable once payment_status value-set is confirmed (PRD §10)
)
SELECT
  a.info_sessions,
  a.intros_only + a.intro_plus_intake                                   AS intros_total,
  a.intro_plus_intake                                                   AS intros_with_intake,
  r.paid_registrations,
  round(100.0 * (a.intros_only + a.intro_plus_intake) / nullif(a.info_sessions,0), 1) AS info_to_intro_pct,
  round(100.0 * r.paid_registrations / nullif(a.intros_only + a.intro_plus_intake,0), 1) AS intro_to_paid_pct
FROM appt a CROSS JOIN reg r;


-- ---------------------------------------------------------------------------
-- #2 / #10 / #31 — Menopause orientation & info-session counts per week
--      orientation 19 (admin) ; menopause info session 25
-- ---------------------------------------------------------------------------
SELECT
  date_trunc('week', (start_time::timestamptz AT TIME ZONE 'America/Toronto'))::date AS week,
  count(*) FILTER (WHERE appointment_type_id = 19) AS menopause_orientation,
  count(*) FILTER (WHERE appointment_type_id = 25) AS menopause_info_session
FROM   appointments
WHERE  lower(trim(status)) = 'active'
AND    appointment_type_id IN (19, 25)
GROUP  BY 1
ORDER  BY 1;


-- ---------------------------------------------------------------------------
-- #27 / #28 — Scheduled intro-only (2,14) and intro+intake (13) per week & month
-- ---------------------------------------------------------------------------
SELECT
  date_trunc('week',  (start_time::timestamptz AT TIME ZONE 'America/Toronto'))::date AS week,
  date_trunc('month', (start_time::timestamptz AT TIME ZONE 'America/Toronto'))::date AS month,
  count(*) FILTER (WHERE appointment_type_id IN (2, 14)) AS intro_only,
  count(*) FILTER (WHERE appointment_type_id = 13)       AS intro_plus_intake
FROM   appointments
WHERE  lower(trim(status)) = 'active'
AND    appointment_type_id IN (2, 13, 14)
GROUP  BY 1, 2
ORDER  BY 1;


-- ---------------------------------------------------------------------------
-- #29 / #32 — New paid registrations per week & month (by start_date)
--      NOTE: "paid" filter (payment_status) pending value-set confirmation (PRD §10)
-- ---------------------------------------------------------------------------
SELECT
  date_trunc('week',  start_date)::date AS week,
  date_trunc('month', start_date)::date AS month,
  count(*) FILTER (WHERE service_id IN ('7ddbbc03-e7db-43b3-862d-edd991cd44df','6272ba51-9041-4efa-8d85-3c99e48473e1')) AS longevity_regs,
  count(*) FILTER (WHERE service_id = 'f807683b-0aec-4643-90ed-1542debf542f') AS menopause_regs
FROM   user_service_enrollments
WHERE  start_date >= now() - interval '6 months'
-- AND  payment_status = 'paid'   -- enable once confirmed
GROUP  BY 1, 2
ORDER  BY 1;


-- ---------------------------------------------------------------------------
-- #11 / 11.1 / 11.2 — Menopause registrations: one-time vs monthly
-- ---------------------------------------------------------------------------
SELECT
  sp.billing_model,
  count(*)                AS registrations,
  sum(e.total_amount)     AS gross_amount
FROM   user_service_enrollments e
JOIN   service_prices sp ON sp.id = e.service_price_id
WHERE  e.service_id = 'f807683b-0aec-4643-90ed-1542debf542f'
AND    e.status = 'active'
GROUP  BY 1
ORDER  BY 1;


-- ---------------------------------------------------------------------------
-- #7 — Churned in the last 30 days (longevity)
-- ---------------------------------------------------------------------------
SELECT count(DISTINCT user_id) AS churned_30d
FROM   user_service_enrollments
WHERE  status = 'cancelled'
AND    canceled_at >= now() - interval '30 days'
AND    service_id IN (
         '7ddbbc03-e7db-43b3-862d-edd991cd44df',
         '6272ba51-9041-4efa-8d85-3c99e48473e1');


-- ---------------------------------------------------------------------------
-- #17 — Patients by MRP (assigned_clinician_id)
--      NOTE: assigned_clinician_id FKs to admins, not clinicians (PRD §10 Q1).
--      Resolve the MRP source before treating this as authoritative.
-- ---------------------------------------------------------------------------
SELECT
  assigned_clinician_id        AS mrp,
  count(DISTINCT user_id)      AS patients
FROM   user_service_enrollments
WHERE  status = 'active'
AND    service_id IN (
         '7ddbbc03-e7db-43b3-862d-edd991cd44df',
         '6272ba51-9041-4efa-8d85-3c99e48473e1')
GROUP  BY 1
ORDER  BY patients DESC;


-- ---------------------------------------------------------------------------
-- #26 / 26.1 / 26.2 — LTV per patient + program averages
--      succeeded payments minus refunds, grouped by user, then cohorted by program
-- ---------------------------------------------------------------------------
WITH net_per_user AS (
  SELECT
    t.user_id,
    sum(t.amount) FILTER (WHERE lower(t.status) = 'succeeded' AND t.type <> 'refund') -
    coalesce(sum(t.amount) FILTER (WHERE t.type = 'refund'), 0) AS ltv
  FROM transactions t
  GROUP BY t.user_id
),
program AS (    -- pick each user's primary active program
  SELECT DISTINCT ON (user_id)
    user_id,
    CASE
      WHEN service_id IN ('7ddbbc03-e7db-43b3-862d-edd991cd44df','6272ba51-9041-4efa-8d85-3c99e48473e1') THEN 'Longevity'
      WHEN service_id = 'f807683b-0aec-4643-90ed-1542debf542f' THEN 'Menopause'
      ELSE 'Other'
    END AS program
  FROM user_service_enrollments
  ORDER BY user_id, start_date DESC
)
SELECT
  p.program,
  count(*)                       AS patients,
  round(avg(n.ltv))              AS avg_ltv,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY n.ltv)) AS median_ltv
FROM net_per_user n
JOIN program p USING (user_id)
GROUP BY p.program
ORDER BY avg_ltv DESC;


-- ---------------------------------------------------------------------------
-- #34 — Renewal value, next 30 days (100% retention assumption)
-- ---------------------------------------------------------------------------
SELECT
  count(*)            AS memberships_renewing,
  sum(total_amount)   AS renewal_value_100pct
FROM   user_service_enrollments
WHERE  status = 'active'
AND    current_period_end >= now()
AND    current_period_end <  now() + interval '30 days';


-- ---------------------------------------------------------------------------
-- CONSUMED CARE — visits per member / month + total NP clinical hours
--   Consumed care = NP-clinician visit, type NOT in the funnel/admin exclusion list.
--   Both safeguards in place: NP-clinician join AND type-exclusion backstop (PRD §2).
-- ---------------------------------------------------------------------------
WITH np_visits AS (
  SELECT
    a.user_id,
    date_trunc('month', (a.start_time::timestamptz AT TIME ZONE 'America/Toronto'))::date AS month,
    at.duration AS minutes
  FROM   appointments a
  JOIN   clinicians  c  ON c.id = a.clinician_id AND c.active = true
                        AND c.id <> 'eaa2867e-54de-4b3c-a5fd-bda4a2a4fbb8'   -- exclude "Information Session"
  JOIN   appointment_types at ON at.id = a.appointment_type_id
  WHERE  lower(trim(a.status)) = 'active'
  AND    a.appointment_type_id NOT IN (2, 13, 14, 8, 10, 25, 19, 26)        -- exclude funnel/admin types
),
per_member AS (
  SELECT month, user_id, count(*) AS visits
  FROM np_visits
  GROUP BY month, user_id
)
SELECT
  pm.month,
  round(avg(pm.visits), 2)                                          AS avg_visits_per_member,
  percentile_cont(0.5) WITHIN GROUP (ORDER BY pm.visits)            AS median_visits,
  max(pm.visits)                                                    AS max_visits,
  (SELECT round(sum(minutes)/60.0, 1) FROM np_visits v WHERE v.month = pm.month) AS total_np_hours
FROM per_member pm
GROUP BY pm.month
ORDER BY pm.month;


-- ---------------------------------------------------------------------------
-- ACQUISITION — new members by discovery source, trended by month
-- ---------------------------------------------------------------------------
SELECT
  date_trunc('month', e.start_date)::date AS month,
  ds.name                                 AS source,
  count(DISTINCT e.user_id)               AS new_members
FROM   user_service_enrollments e
JOIN   users_discovery_sources uds ON uds.user_id = e.user_id
JOIN   discovery_sources       ds  ON ds.id = uds.discovery_source_id
WHERE  e.status = 'active'
AND    e.start_date >= now() - interval '6 months'
GROUP  BY 1, 2
ORDER  BY 1, new_members DESC;


-- ---------------------------------------------------------------------------
-- TIER 3 (#11 lead-time proxy) — booking lead time per NP, no Acuity dependency
--   created_at (booked) vs start_time (visit) → days booked ahead.
--   Rising lead time is the direct supply-tightening signal.
-- ---------------------------------------------------------------------------
SELECT
  c.id                                                    AS clinician_id,
  date_trunc('week', (a.start_time::timestamptz AT TIME ZONE 'America/Toronto'))::date AS visit_week,
  round(avg(
    EXTRACT(epoch FROM (a.start_time::timestamptz - a.created_at::timestamptz)) / 86400.0
  )::numeric, 1)                                          AS avg_days_booked_ahead,
  count(*)                                                AS visits
FROM   appointments a
JOIN   clinicians c ON c.id = a.clinician_id AND c.active = true
                    AND c.id <> 'eaa2867e-54de-4b3c-a5fd-bda4a2a4fbb8'
WHERE  lower(trim(a.status)) = 'active'
AND    a.appointment_type_id NOT IN (2, 13, 14, 8, 10, 25, 19, 26)
AND    a.created_at IS NOT NULL
GROUP  BY 1, 2
ORDER  BY 2, 1;
