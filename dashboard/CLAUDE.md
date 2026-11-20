---
description: Dashboard architecture and conventions — Routes → Pages → Views, TanStack Router/Query, RHF + Zod, Tailwind v4 + shadcn/ui, MapLibre + uPlot, mock backend, read-API contract
globs: dashboard/**/*.ts,dashboard/**/*.tsx,dashboard/**/*.css,dashboard/**/*.html
alwaysApply: false
scope: This rule applies ONLY to `dashboard/` in the DataInfrastructure_Chuds repository.
---

# Dashboard (Road & Ride)

Adapted from the team's frontend rule. Project-specific parts of that rule (auth, `/api/v1` on port
8090, PDF export, password generation, Romanian copy) do not apply here; the plan in
`decisions/02-infrastructure-plan.md` wins where they differ (folder `dashboard/`, MapLibre + uPlot,
read API under `/api/...`).

## Project Description

You are a Principal Frontend Engineer and React Architect with 15+ years of experience.

This is the web dashboard of the Codelap 2026 project: road roughness and motion sickness measured with
phone sensors in cars, buses and trams, sent to Azure live while driving. The **live view is the main
screen** (`/` redirects to `/live`); it also shows the aggregated map of finalized trips (H3 road
segments), sessions, data quality and the method. It reads only from the **read API** — its contract is [API.md](API.md),
its types are in `src/types/`. Until the backend is deployed the dashboard runs on the **mock backend**
(`src/mock/`), which implements the same routes.

## Tech Stack

- React 19 (React Compiler via `babel-plugin-react-compiler` + `@rolldown/plugin-babel`)
- TypeScript 6 (strict; TS 7.0 is not yet supported by dependency-cruiser)
- Vite 8
- TanStack Router (file-based routing via `@tanstack/router-plugin`), TanStack Query 5
- React Hook Form 7 + Zod 4 (`@hookform/resolvers`)
- Tailwind CSS v4 + shadcn/ui (radix-nova); icons: `lucide-react`
- HTTP: `axios` (`@/config/api-client`); env: `@t3-oss/env-core` (`@/config/env`)
- Toasts: `sonner`; theming: `next-themes`; head: `react-helmet-async`; dates: `dayjs`; animation: `motion`
- Maps: `maplibre-gl` with OpenFreeMap tiles; charts: `uplot`; H3: `h3-js` (mock backend only)
- Tests: Vitest + Testing Library (unit), Playwright (e2e smoke)

## General Principles

Production-ready code only. Prioritize clean architecture, SOLID, composition, separation of concerns,
type safety, accessibility (WCAG 2.1 AA), performance and maintainability. Never write quick hacks. If
multiple approaches exist, explain the trade-offs and recommend the best one.

## React Guidelines

- Functional components and hooks only; small, single-responsibility components.
- Never create unnecessary `useEffect`; derive state instead of duplicating it. Effects are for
  synchronizing with external systems (MapLibre, uPlot, timers), not for data flow.
- Memoize only when it measurably helps (the React Compiler handles most cases).
- Custom hooks for reusable logic.

## TypeScript Guidelines

- Never `any`; prefer `unknown`. Discriminated unions where appropriate (`DataSource`).
- Interfaces for object contracts; every prop fully typed.

### Where types live

Exported interfaces and type aliases live in `src/types/<domain>/` (`common`, `sessions`, `segments`,
`live`, `overview`, `map`, `charts`, `config`, `router`). Import with `import type { … } from "@/types/<domain>"`.
Allowed exceptions (stay colocated): `z.infer` types next to their schema in `schema.ts`, component `Props`,
file-private helper types, `typeof` types derived from a constant in the same file, module augmentations,
and generic option types owned by a shared component (`SourceLayer` of `GeoJsonLayer`). The mock backend's
internal simulation types stay inside `src/mock/` (they are not part of the app's domain).

## Architecture: Routes → Pages → Views

```text
src/
├── routes/        # TanStack file routes (thin): validateSearch + page component. routeTree.gen.ts is generated
├── pages/         # Helmet <title> + PageWrapper + the View. Exceptions: the full-screen Map and Live pages,
│                  # and the Session page, which renders its own header (back link, badges) in a <main>
├── views/<feature>/
│   ├── index.tsx  # the screen
│   ├── schema.ts  # Zod schemas (search params, forms) + inferred types
│   ├── components/
│   └── utils/     # view-only helpers and constants.ts
├── api/<feature>/index.ts   # axios calls + TanStack Query hooks; exports `<feature>Api` + `<FEATURE>_QUERY_KEY`
├── components/    # shared components (map/, charts/, status/, query-state, stat-card, page-wrapper); ui/ = shadcn
├── features/      # self-contained widgets (data-quality panel, data-source settings)
├── layouts/       # app shell
├── hooks/         # use-toast, use-theme-colors, use-now
├── config/        # api-client.ts (axios), env.ts, runtime-config.ts (/config.json + data-source resolution)
├── constants/     # index.ts (general), <entity>.ts (shared across layers)
├── utils/         # pure formatters and helpers
├── types/         # all domain types
└── mock/          # in-browser mock backend (axios adapter), lazily loaded
```

- **routes/** never contain logic. Search params are validated with Zod (`views/<feature>/schema.ts`) and
  are the state of filters, so every view is a shareable link.
- **api/** is the only place that talks to the network. Never call `fetch`/`axios` or read
  `import.meta.env` from components.
- **mock/** is reachable only through `configureApiClient` (dynamic import), enforced by depcruise.
  The mock implements the API contract exactly; when the contract changes, change `src/types/`,
  `API.md` and the mock together.
- No runtime import cycles (`npm run depcruise`).

### Create a new route

1. Add `src/routes/<name>.tsx` (or a folder for nested routes) with `createFileRoute`.
2. Add `pages/<name>/index.tsx` and `views/<name>/index.tsx`.
3. Run `npm run dev` or `npm run build` so `routeTree.gen.ts` regenerates (commit it).

## TanStack Query

- Stable query keys built from `<FEATURE>_QUERY_KEY`. `staleTime` long for processed data
  (`STATIC_STALE_TIME_MS`). Polling: the live view every 2 s (`LIVE_POLL_INTERVAL_MS`, plan §5, no retries —
  polling is the retry); recording/processing trips every 5 s until finalized; aggregates every 60 s
  (they change whenever a trip is finalized). Finalized trips never poll.
- A trip's own data (series, track, events, labels) is keyed by "finalized", so it is fetched once more
  when the finalize job replaces the live results.
- Every response passes `expectShape` (`utils/api-shape.ts`) and the client rejects non-JSON answers.
- Handle loading, empty, error and success with `QueryState`. Pass `hasData`: a failed background refresh
  keeps the loaded content with a small notice; the full error replaces the page only when nothing loaded.
  Exceptions: map overlays (overview strip, segment/event/track errors) use `ErrorAlert` directly so the
  map stays visible.
- Never copy server state into local state.

## Forms

React Hook Form + Zod + `zodResolver`; validation only in the schema; `z.input`/`z.output` for form types
when the schema transforms; `useWatch` instead of `watch` (React Compiler compatible). Use
`shouldUnregister: true` only for forms reused across entities; a field that is merely hidden (e.g. the API
URL in mock mode) stays registered, and the schema decides when it is validated.

## Domain rules the UI must keep (plan 02 §5, §8, §10; API.md)

- `source` = how a trip reached the cloud (Streamed / Uploaded / Replay); `status` = Recording →
  Processing → finalized; `incomplete` is a separate flag. Never call a finalized streamed trip "live".
- Only finalized trips count in the map; always show *why* a trip doesn't (`EXCLUSION_LABELS`).
- Live freshness is measured on the server clock and distinguishes "behind the phone", "no data"
  (dead zone), "catching up" (backlog after a dead zone), "trip ended" and "read API unreachable" — never
  claim "live" for old data, never blame the phone for the dashboard's own outage.
- Map layers: segments and tracks are inserted below the event dots (`beforeId`), whatever order requests
  finish in. Everything on the map must also be reachable by keyboard (the worst-segments list).

## Maps and charts

- `MapCanvas` owns the MapLibre instance and exposes it after `style.load` (not `load`, so data never
  waits for base-map tiles). If the style cannot be fetched (offline), it switches to a plain fallback
  style and data layers still render.
- Add data with `GeoJsonLayer` (declarative source + layers); never call `map.addLayer` in views.
- Map and chart colours come from CSS tokens via `useThemeColors` — one source for legend and paint. It
  re-reads them when `<html>`'s class changes (after next-themes applied the theme), never on theme state.
- `GeoJsonLayer` creates its source and layers once per style and applies later spec changes in place
  (`setPaintProperty` / `setLayoutProperty` / `setFilter`), so layer order is stable and data isn't re-uploaded.
- `TimeSeriesChart` wraps uPlot; charts in one view share a `syncKey` cursor.

## Styling

- Tailwind v4 + shadcn/ui; merge classes with `cn()` from `@/lib/utils`.
- No inline `style={{}}` except runtime geometry or runtime CSS-variable colours (legend swatches).
- Colours only from semantic tokens in `src/global.css` (`card`, `muted`, `border`, `foreground`,
  `accent` (blue), `success`, `warning`, `info`, `destructive`, `highlight`, `scale-1…5`, `event-*`,
  `chart-1…5`); never raw palette classes. Text on coloured surfaces uses `*-foreground`.
- Layout helpers `horizontal` / `vertical`; `gradient-bg`; `bg-background-hover`.
- Dark mode via `next-themes` (class strategy).

### Accessibility (WCAG 2.1 AA)

Never remove focus outlines (use `focus-visible:ring-2 focus-visible:ring-ring`); 4.5:1 text contrast in
both themes; correct ARIA (`aria-label` on icon-only buttons and maps, `aria-live` for validation
messages, `aria-current` on the active nav link); tables have headers.

## Project Conventions

- File and folder names kebab-case; `.tsx` only with JSX. Exceptions: `routes/` (TanStack, e.g.
  `$sessionId.tsx`) and `components/ui/` (shadcn).
- Closed sets are const objects + `typeof` types, not `enum`s.
- `cond && <X />`; ternaries only when both branches render something.
- Toasts only via `useToast()`.
- Dates via `@/utils/format-date-time`, numbers/units via `@/utils/format-number`; no local `Intl` or
  `dayjs().format` in features.
- `Button` supports `leftIcon`.
- No magic numbers/strings: general values in `constants/index.ts`, shared ones in
  `constants/<entity>.ts`, view-only ones in `views/<feature>/utils/constants.ts`. Physical constants
  in `constants/units.ts`.
- UI copy is **English** (the rest of the project and the jury material are English).

## Testing

- Pure logic (`utils/`, `mock/`, view utils) has Vitest unit tests next to it (`__tests__/`).
- The mock backend tests pin the plan's rules (replays never aggregated, privacy trimming, β recovered
  by the fixed-effects fit, crowd-confirmed potholes).
- `npm run test:e2e` builds, serves and clicks through every route in Chromium and fails on console errors;
  `e2e/accessibility.spec.ts` runs axe-core (WCAG 2.1 AA) on every route in light and dark mode.
- A change is done when `npm run check` and `npm run build` pass with zero errors.
