# beOptimal Clinic Analytics Dashboard — Product Requirements Document

**Owner:** Peter
**Audience:** Engineering
**Stack:** Supabase (Postgres) → Metabase
**Status:** Draft v2

---

## 1. Purpose & North-Star Questions

This dashboard exists to answer two questions at a glance, every day:

1. **Are we supply-constrained on clinician hours?** (How close are our longevity NPs to capacity, and when do we hit it?)
2. **How is top-of-funnel and conversion trending vs last week / last month?**

Everything else is supporting detail beneath those two headline answers.

---

## 2. Data Model & Conventions

All data lives in the Supabase `public` schema.

| Entity | Table | Notes |
|---|---|---|
| Patients | `users` | `first_name`, `last_name`, `birth_*`, `gender`, `stripe_customer_id`, free-text `admin_notes` |
| Clinicians (NPs) | `clinicians` | `active` flag, `acuity_calendar_id`; includes a non-clinical pseudo-provider **"Information Session"** that must be excluded |
| Appointments | `appointments` | `user_id`, `clinician_id`, `appointment_type_id`, `start_time`/`end_time` (**text, ISO-8601 UTC**), `created_at` (booking time), `status` |
| Appointment types | `appointment_types` | `name`, `duration` (minutes, reliable), `mode`; `initial` (**unreliable — do not use**) |
| Programs / memberships | `user_service_enrollments` | source of truth for membership; `service_id`, `service_price_id`, `assigned_clinician_id`, `status`, `start_date`, `current_period_end`, `canceled_at`, `total_amount`, `payment_status` |
| Program catalog | `service_catalog` | `name`, `type` (subscription / protocol / a_la_carte / member_addon) |
| Pricing | `service_prices` | `billing_model` (recurring / one_time / installment), `interval`, `amount` |
| Revenue | `transactions` | `amount`, `type`, `status`, `tax_amount`, `transaction_date` |
| Acquisition source | `users_discovery_sources` + `discovery_sources` | Meta / Google / referral attribution |
| Visit credits | `service_credit_allowances` + `user_credit_usage` | per-membership visit entitlements & consumption |

### Conventions (apply to every query)

- **Timezone:** always convert before grouping by date:
  `(start_time::timestamptz AT TIME ZONE 'America/Toronto')`. Raw values are UTC.
- **Appointment "booked/attended" filter:** `lower(trim(status)) = 'active'` — defends against the dirty `"cancelled\n"` and the `null` row. Do **not** use `status = 'active'` raw.
- **Longevity core = TWO service IDs:** `Longevity Membership Core` + legacy `Enhanced Care`. Always `service_id IN (both)`.
- **Visit duration** comes from `appointment_types.duration`, never `end_time − start_time`.
- **Enrollment source of truth** is `user_service_enrollments` (376 active rows confirmed). Legacy `subscriptions`/`subscription_items` are deprecated.

### Definition: Funnel vs Consumed Care (decided)

- **Funnel / sales / admin touches — NOT clinical visits.** Info sessions (types 8 phone, 10 video) are the **first person-to-person sales interaction**, conducted by **administrative care coordinators**. Menopause orientation (type 19) is conducted by **admins** (Cheryl Cairns / Peter). InBody scans (type 26) are admin-staffed. None of these count as consumed care; the info session is, however, tracked as the **top of the longevity funnel**.
- **Consumed care = a visit WITH AN NP CLINICIAN** (Oostwoud, Dufour, Penton, Xu, Santos). Operationally: appointment whose `clinician_id` is an active NP (`clinicians.active = true` excluding "Information Session") **and** whose type is not a funnel/admin type. **Excluded types:** `2, 13, 14, 8, 10, 25, 19, 26`. **Counted:** Annual Health Exam (3), Longevity Appointments (9, 15), General Medical (1, 6, 11), Short General (18), and menopause clinical visits (20–24) when NP-conducted.

> **Data note for engineering:** confirm how admin-staffed appointments (InBody, orientation) populate `clinician_id`. If they reference `null` or a non-NP, the NP-clinician join alone excludes them; the type-exclusion list is a backstop in case any are booked onto an NP's calendar. Both safeguards are in the queries.

See **Appendix A** for the full ID reference, including NP clinician IDs.

---

## 3. Tier 1 — Build Now (existing schema, no new data required)

Fully buildable today. SQL starter library delivered separately (`tier1_metabase_queries.sql`).

| # | Metric | Source | Logic |
|---|---|---|---|
| 3 | Active longevity core members | `user_service_enrollments` | `service_id IN (core, enhanced)`, `status='active'`, distinct `user_id` |
| 9 | Active menopause foundation members | `user_service_enrollments` | `service_id = WHHP`, `status='active'` |
| 13 | Total active across both | `user_service_enrollments` | union of the two |
| 1 | WoW info sessions + intros — longevity | `appointments` | info `8,10`; phone intro `14`; in-person `2`; intro+intake `13` |
| 6 / 6.1–6.4 | Intro totals & splits | `appointments` | types `2,13,14` (+ info `8,10` as the top stage) |
| 2 / 10 / 31 | Menopause orientation / info-session counts | `appointments` | orientation `19`; menopause info `25` |
| 27 / 28 | Scheduled intro-only / intro+intake per week·month | `appointments` | types `2,14` / `13` |
| 29 / 32 | New paid registrations per week·month | `user_service_enrollments` | by `start_date`; "paid" via `payment_status` (pending — see §10) |
| 11 / 11.1 / 11.2 | Menopause registrations, one-time vs monthly | `user_service_enrollments` + `service_prices` | split on `billing_model` |
| 7 | Churned last 30 days — longevity | `user_service_enrollments` | `status='cancelled'`, `canceled_at >= now()-30d` |
| 17 | Patients by MRP | `user_service_enrollments` | `assigned_clinician_id` (source pending — see §10) |
| 26 / 26.1 / 26.2 | LTV per patient & program averages | `transactions` | succeeded payments − refunds, grouped by user, then cohorted |
| 34 | Renewal value next 30d (100% retention) | `user_service_enrollments` | `current_period_end` in next 30d, sum `total_amount` |
| — | Visits per member / month + total NP hours | `appointments` + `appointment_types` | consumed-care definition; avg/median/max distribution |
| — | New members by acquisition source | `users_discovery_sources` | trend by Meta / Google / referral |

**Conversion-rate note (6.1–6.4):** your spec defines these as `intros ÷ (active + former patients)`. That's a ratio against the cumulative base, not a true funnel rate. Build **both**: your ratio and the standard `paid registrations ÷ intros` over a trailing window.

---

## 4. Tier 2 — Blocked on Missing Data Capture (schema additions required)

Cannot be charted — the fields do not exist, and nothing can be backfilled for periods before they are added.

| Metric(s) | Missing capture | Proposed schema addition |
|---|---|---|
| 14, 4.1, 4.2, 12.1 (DNC master + subsets) | No structured do-not-contact flag/reason | `users.do_not_contact boolean` + `users.dnc_category text` (enum: `terminated_by_clinic`, `cancelled_conflictual`, `cancelled_neutral`, `upset_other`) |
| 4.2 / 4.3 (cancellation grounds) | No cancellation-reason category | `user_service_enrollments.cancellation_category text` (enum: `conflictual`, `neutral`, `non_payment`, `clinic_initiated`) |
| 5.1 / 5.2 (approved-but-never-joined / declined by NP) | No NP intro decision recorded | `user_service_enrollments.intro_outcome text` (enum: `approved_joined`, `approved_not_joined`, `declined_by_np`) or an `intro_dispositions` table keyed to the intro appointment |
| 4.4 (mailing list: former ex-DNC) | Derivable once DNC flag exists | none beyond DNC flag + existing `mailing_list_subscriptions` |
| 15 (menopause non-completion churn) | No `no_show` status; no completion marker | add `no_show` to appointment status; add `user_service_enrollments.completion_status` |

---

## 5. Tier 3 — Capacity & Utilization (#17–25)

**Partial blocker:** true slot utilization (#18) needs each NP's *availability / manual blocks*, which live only in **Acuity**. `appointments` holds booked slots only.

1. **Booking-lead-time proxy (no Acuity dependency):** `created_at` (booked) vs `start_time` (visit) → days booked ahead, per NP. Rising lead time is the direct signal for "can we hold routine visits under 1 week" (#19–21). Built now (query 11).
2. **Acuity availability sync (unblocks #18 + forward-booking density):** pull NP availability + manual blocks into a new `clinician_availability` table; then utilization = booked ÷ available minutes.

**Panel-size capacity model (#22–25):**

```
max_panel(NP) = annual_available_clinical_minutes(NP) / expected_minutes_per_member_per_year
expected_minutes_per_member_per_year = avg_visits_per_member_per_year * avg_visit_duration
weeks_to_capacity(NP) = (max_panel - current_panel) / net_new_members_per_week
```

Inputs: `current_panel` from `assigned_clinician_id`; visit-rate & duration from the consumed-care usage query; available minutes from NP schedule constants (or Acuity). Recompute per-member-minutes quarterly. Oostwoud (#20) is the complex case — longevity **plus** menopause foundation load plus unknown post-program ongoing-care frequency; model her menopause load separately and sum. The NP set auto-includes new hires, which matters given active hiring.

---

## 6. Tier 4 — Predictive Models (#8, 16, 22–24, 30, 33, 35, 36)

**Metabase cannot train or run models.** A model job (Python / Blair pipeline) writes scores to a `predictions` table (`user_id, model, score, horizon, computed_at`); Metabase reads it like any other table.

**v1 (no ML):** trailing-window churn rate applied forward; at-risk = no visit in N days or failed last payment; registrations via run-rate extrapolation of `start_date`; churn-adjusted renewal value = 100%-retention value × (1 − heuristic churn). Upgrade later without touching Metabase.

---

## 7. Tier 5 — Future / External (#37)

Attio CRM conversion flow: requires an Attio → Supabase sync (or Metabase connector) first. Park until it exists.

---

## 8. Dashboard UX — Simple & Obvious

**Design intent: a single screen that answers the two north-star questions in under five seconds, with zero clicks.** Detail lives below the fold for when someone wants to dig in. Principles:

**Two-band hero, always visible without scrolling.** The top of the page is split into exactly two horizontal bands, mirroring the two questions:

- **Band 1 — "Are we full?" (Supply).** One card per NP, each a single capacity gauge showing **% of panel used** with a **traffic-light color** (green < 70%, amber 70–90%, red > 90%) and one line of text underneath: *"~N weeks to capacity."* That's it. A clinic operator should glance at this row and instantly know who to worry about.
- **Band 2 — "Is the funnel healthy?" (Demand).** A row of large **single-number tiles**: info sessions this week, intros this week, paid registrations MTD, 30-day churn. **Every tile shows its own comparison inline** — a small ▲/▼ with "+12% vs last week" beneath the number, colored green for good-direction and red for bad. This is the entire answer to "how are we doing vs last week / month," and it requires no chart-reading.

**One global date filter, sensible defaults.** A single date control at the top governs the whole page, defaulting to a rolling view (this week + trailing 8 weeks). No per-card date pickers — one knob, everything responds.

**Consistent color grammar everywhere.** Green = healthy / on-track, amber = watch, red = act now. Use the *same* three colors on every card so color always means the same thing. Avoid rainbow palettes.

**A single "Needs attention" strip.** Directly under the hero, one thin row that only appears when something is red: e.g. *"Penton at 94% capacity · Churn up 40% vs last month."* If nothing's wrong, it's empty. This turns the dashboard from "data you must interpret" into "a system that tells you when to look."

**Minimal chart vocabulary below the fold.** Only three shapes: **big numbers** (KPIs), **simple bars** (counts over time — funnel stages, registrations, acquisition source), and **one or two lines** (booking lead time per NP, visits-per-member trend). No pie charts, no donuts, no stacked-everything. One histogram for the usage distribution. White space is a feature.

**Plain-language labels.** Cards say "New menopause patients this month," never `user_service_enrollments`. The dashboard speaks clinic, not schema.

**Section order top-to-bottom:** (1) Supply hero, (2) Demand hero, (3) Needs-attention strip, (4) Funnel detail, (5) Capacity detail (lead-time lines, usage histogram), (6) Revenue (LTV by program, upcoming-renewal value). Anyone can stop reading after the hero and still have their answer.

---

## 9. Data-Quality Fixes (do early)

1. Normalize `appointments.status` — fix the `"cancelled\n"` and `null` rows.
2. Add `no_show` as a valid appointment status and start recording it.
3. Consider migrating `appointments.start_time`/`end_time` from `text` to `timestamptz`.
4. Confirm `user_service_enrollments.payment_status` value set.

---

## 10. Open Questions / Decisions Needed

1. **MRP source (pending):** `user_service_enrollments.assigned_clinician_id` FKs to `admins`, not `clinicians`. Is it the MRP field, or should MRP derive from appointment history? (#17)
2. **`payment_status` values (pending):** needed for the "paid registration" filters (#29, #32). Run `select payment_status, count(*) from user_service_enrollments group by 1;`
3. **Conversion-rate denominator:** your ratio vs standard funnel rate — which is the headline? (#6.x)

*Resolved in v2:* info sessions are the first (admin-staffed) funnel stage and are not clinical visits; consumed care = NP-clinician visits only (InBody and menopause orientation excluded, AHE and Longevity Appointments included).

---

## Appendix A — ID Reference

**Service IDs (`service_catalog`):**

- Longevity Membership Core (subscription): `7ddbbc03-e7db-43b3-862d-edd991cd44df`
- Enhanced Care — legacy longevity (subscription): `6272ba51-9041-4efa-8d85-3c99e48473e1`
- Women's Hormone Health Protocol — menopause foundation (protocol): `f807683b-0aec-4643-90ed-1542debf542f`

**Appointment-type IDs (`appointment_types`):**

- Info session (admin, top of funnel) — phone: `8`; video: `10`
- Longevity intro — phone: `14`; in-person: `2`; intro + intake (in-person, 60m): `13`
- Menopause orientation (admin, in-person, 30m): `19`; menopause info session (phone): `25`
- Menopause clinical — initial consult `20`; follow-ups `21`/`22`/`23`; annual `24`
- **Consumed-care (NP) visits:** Longevity Appointment `9`/`15`; Annual Health Exam `3`; General Medical `1`/`6`/`11`; Short General `18`
- **Excluded from consumed care:** `2, 13, 14, 8, 10, 25, 19, 26`

**NP clinician IDs (`clinicians`):**

- Lisa Dufour: `e00f4874-8a19-4d99-b814-095fe15b0c44`
- Tina (Ting Na) Xu: `6b649c4f-5165-4069-a69c-cddeacfe309e`
- Chantelle Oostwoud: `19d57efd-47fc-4726-a308-9b643179f68e`
- Lynne Penton: `b39b692e-5476-44fe-b822-6df907a32a45`
- Edite Santos: `80fbd86a-8897-41c4-827f-3505873a7bb8`
- Exclude pseudo-provider "Information Session": `eaa2867e-54de-4b3c-a5fd-bda4a2a4fbb8`
