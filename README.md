# PgRest

PostgREST/Supabase-compatible data query and REST API layer for Elixir, built on Plug and Ecto

Define Ecto schemas, get a full REST API that works with existing PostgREST clients like `@supabase/postgrest-js`. Queries are parsed into Ecto expressions — no raw SQL, no runtime code generation.

## Why PgRest?

[PostgREST](https://docs.postgrest.org/) and [Supabase](https://supabase.com/) are fantastic battle-tested solutions, but they run as separate services. PgRest brings the same query language and client compatibility to Elixir — no sidecar process, no migration from Supabase, just add it to your existing Phoenix or Plug app.

- **Drop-in client compatibility** — Works with `@supabase/postgrest-js` and any PostgREST client. Same URL syntax, same operators, same response format.
- **Ecto-native** — Schemas define your API resources. Filters become `where` clauses, embeds become `preload`, inner joins become `join`. All type-safe through Ecto's query builder.
- **Scoped by default** — `scope/2` callbacks for tenant isolation and soft deletes. Custom `handle_param/4` for search, geo-queries, or any app-specific filter.
- **No extra infrastructure** — It's a Plug. Runs in your existing BEAM process, uses your existing Ecto repo. No separate service to deploy or manage.

## Demo App

See [`demo/`](demo/) for an interactive query explorer built with Phoenix LiveView. It runs 18 example queries live against a seeded project/task database using `@supabase/postgrest-js`, showing the client code, generated SQL, JSON response, and timing for each.

```bash
cd demo && mix setup && mix phx.server
# Visit http://localhost:4000
```

## Prerequisites

- Elixir 1.19+
- PostgreSQL with an Ecto repository
- A Plug-based application (Phoenix, Bandit, etc.)

## Installation

Add `pg_rest` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pg_rest, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### 1. Define a Resource

A resource is an Ecto schema that uses `PgRest.Resource`:

```elixir
defmodule MyApp.API.Tasks do
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Query

  schema "tasks" do
    field :title, :string
    field :status, :string
    field :priority, :string
    belongs_to :project, MyApp.API.Projects
    timestamps()
  end

  # Optional: always-applied query scope (tenant isolation, soft deletes)
  @impl PgRest.Resource
  def scope(query, _context), do: where(query, [t], is_nil(t.deleted_at))

  # Optional: custom URL params (?search=foo)
  @impl PgRest.Resource
  def handle_param("search", value, query, _context) do
    where(query, [t], ilike(t.title, ^"%#{value}%"))
  end

  def handle_param(_, _, query, _), do: query
end
```

### 2. Start the Registry

Add `PgRest.Registry` to your supervision tree. With `:otp_app`, it auto-discovers every module that has `use PgRest.Resource`:

```elixir
children = [
  MyApp.Repo,
  {PgRest.Registry, otp_app: :my_app},
]
```

Or pass an explicit list:

```elixir
{PgRest.Registry, modules: [MyApp.API.Tasks, MyApp.API.Projects]}
```

### 3. Mount the Plug

In your router, forward API requests to `PgRest.Plug`:

```elixir
# Phoenix router
forward "/api", PgRest.Plug, repo: MyApp.Repo

# Plug.Router
forward "/api", to: PgRest.Plug, init_opts: [repo: MyApp.Repo]
```

### 4. Query with Any PostgREST Client

```javascript
import { PostgrestClient } from '@supabase/postgrest-js'

const api = new PostgrestClient('http://localhost:4000/api')

// Filter, order, paginate
const { data } = await api
  .from('tasks')
  .select('title,status,project(name)')
  .eq('status', 'pending')
  .order('due_date', { ascending: true })
  .limit(10)
```

Or with plain HTTP:

```
GET /api/tasks?status=eq.pending&select=title,status,project(name)&order=due_date.asc&limit=10
```

## How It Works

Every request flows through the same pipeline:

```
Base query (from schema)
    |
scope/2 (tenant isolation, soft deletes — always runs)
    |
URL filters (?status=eq.active&priority=eq.high)
    |
handle_param/4 (custom params: ?search=, ?within_miles=)
    |
select, order, limit, offset → Repo.all()
```

URL parameters are parsed into an AST, then applied as Ecto query expressions. The parser handles the full PostgREST operator set: comparison (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`), pattern matching (`like`, `ilike`, `match`), containment (`in`, `cs`, `cd`, `ov`), full-text search (`fts`, `plfts`, `phfts`, `wfts`), logical grouping (`and`, `or`, `not`), and relationship embedding via `select`.

## Using the Query Builder Directly

The parser and filter modules work independently of HTTP. You can use them to build Ecto queries from PostgREST-style parameter maps anywhere — LiveView, GenServers, background jobs:

```elixir
params = %{"status" => "eq.pending", "priority" => "eq.high", "order" => "due_date.asc", "limit" => "10"}

{:ok, parsed} = PgRest.Parser.parse(params, allowed_fields: MyApp.Tasks.__schema__(:fields))
{:ok, filters} = PgRest.TypeCaster.cast_filters(parsed.filters, MyApp.Tasks)

query =
  MyApp.Tasks
  |> PgRest.Filter.apply_all(filters)
  |> PgRest.Order.apply_order(parsed.order)
  |> Ecto.Query.limit(^parsed.limit)

Repo.all(query)
```

The result is a composable `%Ecto.Query{}` — pipe it further, add your own clauses, or pass it to streams.

## Plug Options

```elixir
forward "/api", PgRest.Plug,
  repo: MyApp.Repo,           # Required — Ecto repo module
  json: Jason,                 # JSON encoder (default: Jason)
  max_limit: 1000,             # Max rows per request (default: nil = no limit)
  context_builder: &build/2    # Custom context from conn → map
```

## Resource Callbacks

| Callback          | Purpose                                          | Default              |
|-------------------|--------------------------------------------------|----------------------|
| `scope/2`         | Always-applied query filter (tenancy, soft deletes) | No-op             |
| `handle_param/4`  | Custom URL parameter handling                    | No-op                |
| `changeset/3`     | Create/update changeset                          | Casts all schema fields |
| `after_load/2`    | Post-processing after DB load                    | Identity             |

## Supported Operations

| HTTP Method                            | PostgREST Equivalent  | Description                                  |
|----------------------------------------|-----------------------|----------------------------------------------|
| `GET /resource`                        | `GET /table`          | List with filters, ordering, pagination      |
| `GET /resource?select=a,b,rel(c)`      | Resource embedding    | Preload associations                         |
| `GET /resource?rel.field=eq.x`         | Embedded filters      | Filter on associated records                 |
| `GET /resource?select=*,rel!inner(*)` | Inner join            | Only return rows with matching associations  |
| `POST /resource`                       | `POST /table`         | Create (single or bulk)                      |
| `PATCH /resource?filters`              | `PATCH /table?filters` | Update matching rows                        |
| `DELETE /resource?filters`             | `DELETE /table?filters` | Delete matching rows                       |

## Telemetry

PgRest emits `:telemetry` events for all operations:

```
[:pg_rest, :query, :start]    — %{resource: module, operation: atom, repo: module}
[:pg_rest, :query, :stop]     — includes duration
[:pg_rest, :query, :exception] — on failure
```

## Testing

```bash
mix test
```

## License

MIT
