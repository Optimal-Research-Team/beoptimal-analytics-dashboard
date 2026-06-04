# beOptimal Clinic Analytics Dashboard

A single-screen clinic operations dashboard that answers two north-star questions in under five seconds, with zero clicks:

1. **Are we supply-constrained on clinician hours?** — how close are our longevity NPs to capacity, and when do we hit it.
2. **How is top-of-funnel and conversion trending vs last week / last month?**

This repository contains the **UX mockup** (live, self-contained) and the **Product Requirements Document** for the dashboard, which will be built on **Supabase (Postgres) → Metabase**.

## 🔗 Live mockup

**→ [View the live dashboard mockup](https://optimal-research-team.github.io/beoptimal-analytics-dashboard/)**

> The mockup uses representative (non-production) data to demonstrate layout, color grammar, and information hierarchy. It is a design artifact, not a connected dashboard.

## 📄 Documents

| File | What it is |
|---|---|
| [`PRD.md`](./PRD.md) | Full Product Requirements Document (Draft v2) — data model, metric tiers, capacity model, UX spec, open questions, ID reference |
| [`tier1_metabase_queries.sql`](./tier1_metabase_queries.sql) | Runnable Metabase native-SQL starter library for every Tier 1 metric, with the §2 conventions (timezone, dirty-status filter, service/type IDs) baked in |
| [`index.html`](./index.html) | Self-contained UX mockup (no build step) |

## 🎯 Design intent

The dashboard is built around the principle that **anyone can stop reading after the hero and still have their answer**. Layout, top to bottom:

1. **Demand hero** — large single-number tiles (info sessions, intros, paid registrations MTD, 30-day churn), each with an inline ▲/▼ comparison vs last period.
2. **Supply hero** — one capacity gauge per NP (% of panel used) with a traffic-light color (green `<70%`, amber `70–90%`, red `>90%`) and "~N weeks to capacity."
3. **Needs-attention strip** — appears only when something is red.
4. **Funnel detail** — stage-to-stage conversion, registrations, info-session/intro volume, acquisition source.
5. **Capacity detail** — booking lead-time per NP (the no-Acuity supply proxy) and consumed-care visit distribution.
6. **Revenue** — average LTV by program and upcoming renewal value.

### Color grammar

The same three colors mean the same thing everywhere:

- 🟢 **Green** — healthy / on-track
- 🟡 **Amber** — watch
- 🔴 **Red** — act now

### Chart vocabulary

Deliberately minimal — big numbers (KPIs), simple bars (counts over time), one or two lines (booking lead time), and one histogram (usage distribution). No pie charts, no donuts, no stacked-everything.

## 🛠 Stack (target build)

| Layer | Choice |
|---|---|
| Source data | Supabase (Postgres), `public` schema |
| BI / charting | Metabase |
| Predictive scores | Python job → `predictions` table, read by Metabase like any other table |
| Mockup | Static HTML + inline SVG (no framework, no build) |

The mockup's palette and type are aligned to the **beOptimal brand**: warm cream `#fffcf7`, deep forest green `#2c4e25`, sage and golden accents, set in **Castoro** (serif display) + **Public Sans** (UI) + **JetBrains Mono** (numerics).

## 🧱 Key conventions (see PRD §2)

- **Timezone:** convert before grouping — `(start_time::timestamptz AT TIME ZONE 'America/Toronto')`.
- **Booked/attended filter:** `lower(trim(status)) = 'active'` (defends against dirty `"cancelled\n"` / `null` rows).
- **Longevity core = two service IDs:** `Longevity Membership Core` + legacy `Enhanced Care`.
- **Consumed care = NP-clinician visits only** — info sessions, orientation, and InBody are funnel/admin touches, not clinical visits.
- **Visit duration** comes from `appointment_types.duration`, never `end_time − start_time`.

## 🚀 Local preview

The mockup is a single static file — open it directly or serve it:

```bash
python3 -m http.server 3011
# then visit http://localhost:3011
```

## Deployment

Published via **GitHub Pages** from the repository root on every push to `main` (see `.github/workflows/deploy.yml`).

---

*Built for the Optimal Research Team. Supabase → Metabase · PRD Draft v2.*
