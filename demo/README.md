# PgRest Demo

Interactive query explorer for [PgRest](../), the PostgREST-compatible REST API layer for Elixir

A Phoenix LiveView app that demonstrates PgRest with a seeded project/task database. Each example query runs live against the API using `@supabase/postgrest-js`, showing the client code, generated SQL, JSON response, and timing.

## What It Demonstrates

- **Filtering** — `eq`, `neq`, `gte`, `lt`, `is`, `ilike`, `in`, array `contains`
- **Ordering and pagination** — `order`, `limit`, `offset`
- **Field selection** — Choose which columns to return
- **Relationship embedding** — `has_many` and `belongs_to` preloads via `select=name,tasks(title)`
- **Inner joins** — `select=*,project!inner(name)` with association filters
- **Embedded filters and ordering** — Filter and sort nested records
- **Custom parameters** — App-specific `?search=` param handled by `handle_param/4`

## Prerequisites

- Elixir 1.15+
- PostgreSQL running locally
- Node.js (for frontend assets)

## Setup

```bash
# Install dependencies, create database, run migrations, seed data, build assets
mix setup
```

This runs `deps.get`, `ecto.setup` (create + migrate + seed 7 projects and 120 tasks), `assets.setup`, and `assets.build`.

## Running

```bash
mix phx.server
```

Visit [localhost:4000](http://localhost:4000). Click any query example to execute it live.

## How It Works

The demo defines two PgRest resources:

- **Projects** — `name`, `status`, `budget`, `deadline`, with `has_many :tasks`
- **Tasks** — `title`, `status`, `priority`, `tags` (array), `complexity`, with `belongs_to :project`

Both implement `handle_param("search", ...)` for custom full-text search. Tasks use `scope/2` to exclude soft-deleted records.

The API is mounted at `/api` via `PgRest.Plug`. The frontend uses `@supabase/postgrest-js` to build queries exactly as you would against a real PostgREST or Supabase instance. A debug plug captures the generated SQL via Ecto telemetry and returns it in a response header for display.

## Project Structure

```
demo/
  lib/demo/
    projects/          # Project schema + PgRest resource
    tasks/             # Task schema + PgRest resource
  lib/demo_web/
    live/home_live.ex  # Interactive query explorer
    plugs/             # SqlDebug, ServerTiming, ReadOnlyApi
    router.ex          # /api → PgRest.Plug
  priv/repo/
    seeds.exs          # 7 projects, 120 tasks
  assets/js/
    app.js             # postgrest-js hook, SQL formatting, syntax highlighting
```
