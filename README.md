# ExRest: PostgREST-Compatible REST API for Elixir

## Executive Summary

ExRest is an Elixir library that provides a PostgREST-compatible REST API deeply integrated with Phoenix applications. Define Ecto schemas, get a full REST API with Supabase client compatibility.

**Core Approach:**

```elixir
defmodule MyApp.API.Orders do
  use ExRest.Resource
  import Ecto.Query
  
  schema "orders" do
    field :status, :string
    field :total, :decimal
    belongs_to :user, MyApp.User
    has_many :items, MyApp.OrderItem
  end
  
  # Optional: always-applied filters (tenant isolation, soft deletes)
  def scope(query, context) do
    where(query, [o], o.tenant_id == ^context.tenant_id)
  end
  
  # Optional: custom URL params (?search=foo&date_range=2024-01..2024-02)
  def handle_param("search", value, query, _ctx), do: where(query, [o], ilike(o.ref, ^"%#{value}%"))
  def handle_param(_, _, query, _), do: query
end
```

**Key Features:**
- **Supabase/PostgREST Compatible** - Same URL syntax, headers, JWT handling
- **Ecto-Native** - Schemas define API resources; changesets for mutations
- **Layered Filtering** - `scope/2` callbacks + optional JSON permissions + URL params
- **Type-Safe** - Compile-time atoms, Ecto casting, no SQL injection surface
- **Plugin System** - Extensible operators for PostGIS, pgvector, full-text search
- **Optional Caching** - Nebulex integration (local, distributed, or multi-level)
- **Optional Rate Limiting** - Hammer integration with Redis backend
- **Multi-Node Ready** - libcluster, distributed invalidation, health checks

**Query Pipeline:**
```
Base query (from schema)
    ↓
scope/2 (tenant isolation, soft deletes - always runs)
    ↓
JSON permissions (optional role-based filters from metadata)
    ↓
URL filters (?status=eq.active)
    ↓
handle_param/4 (custom params: ?search=, ?within_miles=)
    ↓
select, order, limit → execute
```

**Contents:**
1. PostgREST Reference - URL syntax, operators, SQL generation patterns
2. ExRest Architecture - Resource behavior, query pipeline, Phoenix integration
3. Comparison - ExRest vs PostgREST vs Hasura
4. Security - Threat model, Ecto advantages, deployment checklist
5. Supabase Compatibility - Headers, JWT, session variables
6. Performance - Native JSON, optional caching
7. Operational - Headers, logging, optional rate limiting
8. Future Considerations - Open questions
9. Extensibility - Plugins, Nebulex, Hammer, multi-node OTP
10. Appendices - Operator reference, code examples

---

## Part 1: PostgREST Reference

### 1.1 Core Architecture Overview

PostgREST is written in Haskell and uses several key architectural patterns:

1. **Schema Cache**: On startup, PostgREST introspects the PostgreSQL schema and caches table/view/function metadata, foreign key relationships, and column types
2. **Request Parser**: Uses Parsec parser combinators to parse URL query parameters into typed AST structures
3. **Query Builder**: Transforms the parsed AST into parameterized SQL queries using hasql
4. **Response Formatter**: Handles content negotiation (JSON, CSV, etc.) using PostgreSQL's `row_to_json()` and `array_agg()` functions

### 1.2 Table Exposure Model (How PostgREST Controls Access)

PostgREST uses a **schema-based exposure model** with PostgreSQL privileges as the access control layer:

#### Configuration: `db-schemas`
```
# Single schema (default)
db-schemas = "api"

# Multiple schemas (multi-tenant)
db-schemas = "tenant1, tenant2, tenant3"
```

#### Key Points:
1. **All-or-nothing at schema level**: Every table, view, and function in the configured schema(s) is exposed via the API
2. **No table-level whitelist/blacklist**: PostgREST has no built-in way to say "expose table A but not table B" within the same schema
3. **PostgreSQL privileges are the gatekeepers**: Access is controlled entirely via SQL `GRANT`/`REVOKE`
4. **Multi-schema support**: Clients select schema via `Accept-Profile` / `Content-Profile` headers

#### PostgreSQL Privilege Model:
```sql
-- Create an API role
CREATE ROLE api_user NOLOGIN;

-- Grant schema access
GRANT USAGE ON SCHEMA api TO api_user;

-- Grant table access (granular control)
GRANT SELECT ON api.users TO api_user;
GRANT SELECT, INSERT, UPDATE ON api.posts TO api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.comments TO api_user;

-- Column-level restrictions
GRANT SELECT (id, name, email) ON api.users TO api_user;  -- hide sensitive columns
GRANT UPDATE (message_body) ON api.chat TO api_user;       -- only allow updating specific columns
```

#### Best Practice: Schema Isolation Pattern
```
┌─────────────────────────────────────────────────────────────┐
│  "api" schema (EXPOSED via PostgREST)                       │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │ users_view      │  │ posts_view      │  <- Views only    │
│  │ (SELECT * FROM  │  │ (SELECT * FROM  │                   │
│  │  private.users) │  │  private.posts) │                   │
│  └─────────────────┘  └─────────────────┘                   │
│  ┌─────────────────┐                                        │
│  │ create_post()   │  <- Functions for complex operations   │
│  └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ References
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  "private" schema (NOT exposed)                             │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │ users (table)   │  │ posts (table)   │  <- Actual tables │
│  │ - id            │  │ - id            │                   │
│  │ - name          │  │ - title         │                   │
│  │ - email         │  │ - user_id (FK)  │                   │
│  │ - password_hash │  │ - body          │                   │
│  └─────────────────┘  └─────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

#### Limitations of PostgREST's Approach:
- **Schema proliferation**: To hide one table, you might need a whole separate schema
- **Complex privilege management**: Must manage grants at database level
- **No runtime configuration**: Can't easily toggle table exposure without schema changes
- **Views overhead**: Creating views for every table adds maintenance burden

### 1.3 URL Structure & Reserved Parameters

```
GET /{table}?{filters}&select={columns}&order={ordering}&limit={n}&offset={n}
POST /{table}
PATCH /{table}?{filters}
DELETE /{table}?{filters}
POST /rpc/{function_name}
```

**Reserved Query Parameters:**
| Parameter | Purpose | Example |
|-----------|---------|---------|
| `select` | Vertical filtering (columns) | `select=id,name,posts(title)` |
| `order` | Ordering | `order=created_at.desc.nullslast` |
| `limit` | Row limit | `limit=10` |
| `offset` | Row offset | `offset=20` |
| `columns` | Specify insert/update columns | `columns=id,name` |
| `on_conflict` | Upsert conflict target | `on_conflict=email` |
| `and` | Logical AND grouping | `and=(age.gt.18,status.eq.active)` |
| `or` | Logical OR grouping | `or=(age.lt.18,age.gt.65)` |
| `not.and` / `not.or` | Negated logical groups | `not.or=(a.eq.1,b.eq.2)` |

### 1.4 Complete Operator Reference

#### Comparison Operators
| Operator | PostgreSQL | Description | Example |
|----------|------------|-------------|---------|
| `eq` | `=` | Equals | `id=eq.5` |
| `neq` | `<>` | Not equals | `status=neq.deleted` |
| `gt` | `>` | Greater than | `age=gt.18` |
| `gte` | `>=` | Greater than or equal | `price=gte.100` |
| `lt` | `<` | Less than | `quantity=lt.10` |
| `lte` | `<=` | Less than or equal | `rating=lte.3` |

#### Pattern Matching Operators
| Operator | PostgreSQL | Description | Example |
|----------|------------|-------------|---------|
| `like` | `LIKE` | Case-sensitive pattern | `name=like.*smith*` |
| `ilike` | `ILIKE` | Case-insensitive pattern | `email=ilike.*@gmail.com` |
| `match` | `~` | POSIX regex | `code=match.^[A-Z]{3}` |
| `imatch` | `~*` | Case-insensitive regex | `name=imatch.^john` |

#### Special Operators
| Operator | PostgreSQL | Description | Example |
|----------|------------|-------------|---------|
| `is` | `IS` | NULL/true/false/unknown | `deleted_at=is.null` |
| `isdistinct` | `IS DISTINCT FROM` | NULL-safe inequality | `a=isdistinct.b` |
| `in` | `IN` | List membership | `id=in.(1,2,3)` |

#### Array Operators
| Operator | PostgreSQL | Description | Example |
|----------|------------|-------------|---------|
| `cs` | `@>` | Contains | `tags=cs.{elixir,phoenix}` |
| `cd` | `<@` | Contained by | `roles=cd.{admin,user}` |
| `ov` | `&&` | Overlaps | `tags=ov.{urgent,important}` |

#### Range Operators
| Operator | PostgreSQL | Description | Example |
|----------|------------|-------------|---------|
| `sl` | `<<` | Strictly left of | `range=sl.[10,20]` |
| `sr` | `>>` | Strictly right of | `range=sr.[10,20]` |
| `nxl` | `&<` | Does not extend to left | `range=nxl.[10,20]` |
| `nxr` | `&>` | Does not extend to right | `range=nxr.[10,20]` |
| `adj` | `-|-` | Adjacent to | `range=adj.[10,20)` |

#### Full-Text Search Operators
| Operator | PostgreSQL Function | Description | Example |
|----------|---------------------|-------------|---------|
| `fts` | `to_tsquery` | Basic FTS | `tsv=fts.cat&dog` |
| `plfts` | `plainto_tsquery` | Plain text FTS | `tsv=plfts.fat cats` |
| `phfts` | `phraseto_tsquery` | Phrase FTS | `tsv=phfts.fat cats` |
| `wfts` | `websearch_to_tsquery` | Web search FTS | `tsv=wfts."fat cats" -dogs` |

All FTS operators support language config: `tsv=fts(english).running`

#### Operator Modifiers
| Modifier | Description | Example |
|----------|-------------|---------|
| `not.` | Negation prefix | `status=not.eq.deleted` |
| `.any` | ANY quantifier | `id=eq.any.{1,2,3}` |
| `.all` | ALL quantifier | `tags=cs.all.{a,b,c}` |

### 1.5 Select Syntax (Vertical Filtering)

The `select` parameter uses a rich grammar:

```
select      = field ("," field)*
field       = column | embed | aggregate
column      = name ["::" cast] [":" alias]
embed       = relation ["!" hint] "(" select ")"
aggregate   = agg_fn "(" column ")"
hint        = fk_name | column_name
```

**Examples:**
```
# Basic columns
?select=id,name,email

# Aliasing
?select=full_name:name,user_email:email

# Type casting
?select=amount::text,created_at::date

# JSON path access
?select=data->settings->>theme

# Resource embedding (joins)
?select=id,name,posts(id,title,comments(body))

# Disambiguated embedding (multiple FKs)
?select=billing_address:addresses!billing(city),shipping_address:addresses!shipping(city)

# Aggregate functions
?select=count(),avg(price),sum(quantity)
```

### 1.6 Filter Syntax (Horizontal Filtering)

Filters use the pattern: `{column}={operator}.{value}`

**Grammar:**
```
filter      = column "=" operator "." value
operator    = ["not."] base_op [modifier]
base_op     = "eq" | "neq" | "gt" | "gte" | "lt" | "lte" | ...
modifier    = ".any" | ".all"
value       = literal | quoted_string | list | range
list        = "(" item ("," item)* ")"
range       = "[" | "(" bound "," bound "]" | ")"
```

**Complex Logic Examples:**
```
# Simple AND (default)
?age=gte.18&status=eq.active

# OR condition
?or=(age.lt.18,age.gt.65)

# Nested logic
?grade=gte.90&or=(age.eq.14,not.and(age.gte.11,age.lte.17))

# Filtering on embedded resources
?posts.published=eq.true

# JSON column filtering
?data->settings->>theme=eq.dark
```

### 1.7 Order Syntax

```
order       = term ("," term)*
term        = column ["." direction] ["." nulls]
direction   = "asc" | "desc"
nulls       = "nullsfirst" | "nullslast"
```

**Examples:**
```
?order=created_at.desc.nullslast,name.asc
?order=data->priority.desc
```

### 1.8 HTTP Headers & Preferences

**Request Headers:**
| Header | Purpose | Values |
|--------|---------|--------|
| `Accept` | Response format | `application/json`, `text/csv`, `application/vnd.pgrst.object+json` |
| `Range` | Pagination | `0-24` |
| `Range-Unit` | Unit for range | `items` |
| `Prefer` | Request preferences | See below |

**Prefer Header Values:**
| Preference | Values | Description |
|------------|--------|-------------|
| `return` | `minimal`, `representation`, `headers-only` | What to return after mutation |
| `count` | `exact`, `planned`, `estimated` | Row counting strategy |
| `resolution` | `merge-duplicates`, `ignore-duplicates` | Upsert behavior |
| `missing` | `default` | Use column defaults for missing values |
| `handling` | `lenient`, `strict` | Error handling |
| `max-affected` | Integer | Limit affected rows |
| `tx` | `commit`, `rollback` | Transaction handling |
| `timezone` | Timezone string | Set session timezone |

### 1.9 SQL Generation Patterns

PostgREST generates SQL using CTEs (Common Table Expressions) for composability:

**Read Query Pattern:**
```sql
WITH pgrst_source AS (
  SELECT {columns}
  FROM {schema}.{table}
  WHERE {filters}
  ORDER BY {ordering}
  LIMIT {limit}
  OFFSET {offset}
)
SELECT
  coalesce(
    (SELECT json_agg(row_to_json(pgrst_source)) FROM pgrst_source),
    '[]'
  )::text AS body,
  (SELECT count(*) FROM pgrst_source) AS page_total
```

**Embedded Resource Pattern (using lateral joins):**
```sql
SELECT
  t.id,
  t.name,
  COALESCE(
    (SELECT json_agg(row_to_json(p))
     FROM (SELECT p.id, p.title FROM posts p WHERE p.user_id = t.id) p),
    '[]'
  ) AS posts
FROM users t
WHERE t.id = $1
```

**Write Query Pattern:**
```sql
WITH pgrst_body AS (
  SELECT $1::json AS body
),
pgrst_payload AS (
  SELECT CASE
    WHEN json_typeof(body) = 'array' THEN body
    ELSE json_build_array(body)
  END AS val
  FROM pgrst_body
)
INSERT INTO {schema}.{table} ({columns})
SELECT {columns} FROM json_populate_recordset(null::{schema}.{table}, (SELECT val FROM pgrst_payload))
RETURNING *
```

### 1.10 Security Model

1. **Row Level Security (RLS)**: PostgREST relies on PostgreSQL's RLS policies
2. **Role Switching**: Uses `SET ROLE` to switch to the authenticated user's role
3. **JWT Claims**: Exposes JWT claims via `current_setting('request.jwt.claims')`
4. **Schema Isolation**: Only exposes tables in configured schemas

---


## Part 2: ExRest Architecture

ExRest requires Ecto schemas to define API resources. This provides compile-time safety, type coercion, and deep Phoenix integration.

### 2.1 ExRest.Resource Behavior

```elixir
defmodule ExRest.Resource do
  @moduledoc """
  Behavior for ExRest API resources.
  
  Use this in your Ecto schema modules to expose them via the REST API.
  """

  @type context :: %{
    user_id: term(),
    role: String.t(),
    tenant_id: term(),
    repo: module(),
    assigns: map()
  }

  @doc """
  Optional: Base query scope applied to all operations.
  Use for tenant isolation, soft deletes, or always-on filters.
  """
  @callback scope(Ecto.Query.t(), context()) :: Ecto.Query.t()

  @doc """
  Optional: Handle custom URL parameters.
  Called for each non-standard query param. Return modified query.
  """
  @callback handle_param(String.t(), String.t(), Ecto.Query.t(), context()) :: Ecto.Query.t()

  @doc """
  Optional: Transform changeset before insert/update.
  """
  @callback changeset(Ecto.Schema.t(), map(), context()) :: Ecto.Changeset.t()

  @doc """
  Optional: Transform records after loading.
  Use for field masking, computed fields, etc.
  """
  @callback after_load(Ecto.Schema.t(), context()) :: Ecto.Schema.t()

  @optional_callbacks [scope: 2, handle_param: 4, changeset: 3, after_load: 2]

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      @behaviour ExRest.Resource
      
      # Register this module as an ExRest resource
      Module.register_attribute(__MODULE__, :exrest_resource, persist: true)
      @exrest_resource true
      
      # Default implementations
      def scope(query, _context), do: query
      def handle_param(_key, _value, query, _context), do: query
      def after_load(record, _context), do: record
      
      defoverridable [scope: 2, handle_param: 4, after_load: 2]
    end
  end
end
```

### 2.2 Resource Module Structure

A complete resource module:

```elixir
defmodule MyApp.API.Orders do
  use ExRest.Resource
  import Ecto.Query
  
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "orders" do
    field :reference, :string
    field :status, :string
    field :total, :decimal
    field :notes, :string
    field :tenant_id, :binary_id
    field :deleted_at, :utc_datetime
    
    belongs_to :user, MyApp.User
    belongs_to :shipping_address, MyApp.Address
    has_many :items, MyApp.OrderItem
    
    timestamps()
  end
  
  # Hasura-compatible JSON permissions (optional, stored in metadata table)
  # These are applied automatically based on role from JWT
  # See section 2.6 for details
  
  # Always-applied scope - runs before everything else
  @impl ExRest.Resource
  def scope(query, context) do
    query
    |> where([o], o.tenant_id == ^context.tenant_id)
    |> where([o], is_nil(o.deleted_at))
  end
  
  # Custom URL parameters - extend beyond PostgREST syntax
  @impl ExRest.Resource
  def handle_param("search", value, query, _context) do
    search = "%#{value}%"
    where(query, [o], ilike(o.reference, ^search) or ilike(o.notes, ^search))
  end
  
  def handle_param("date_range", value, query, _context) do
    case String.split(value, "..") do
      [start_date, end_date] ->
        query
        |> where([o], o.inserted_at >= ^start_date)
        |> where([o], o.inserted_at <= ^end_date)
      _ ->
        query
    end
  end
  
  def handle_param("has_items", "true", query, _context) do
    from o in query,
      join: i in assoc(o, :items),
      group_by: o.id,
      having: count(i.id) > 0
  end
  
  def handle_param(_key, _value, query, _context), do: query
  
  # Changeset for mutations (POST, PATCH)
  @impl ExRest.Resource
  def changeset(order, attrs, context) do
    order
    |> cast(attrs, [:reference, :status, :total, :notes, :user_id, :shipping_address_id])
    |> validate_required([:reference, :status])
    |> validate_inclusion(:status, ["pending", "confirmed", "shipped", "delivered", "cancelled"])
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> put_change(:tenant_id, context.tenant_id)  # Auto-set from context
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:reference, name: :orders_tenant_reference_index)
  end
  
  # Transform after loading (field masking, computed fields)
  @impl ExRest.Resource
  def after_load(order, context) do
    case context.role do
      "admin" -> order
      _ -> %{order | notes: nil}  # Hide internal notes from non-admins
    end
  end
end
```

### 2.3 Resource Registry

ExRest discovers resources at compile-time and runtime:

```elixir
defmodule ExRest.Registry do
  @moduledoc """
  Registry of ExRest resources.
  """
  
  use GenServer
  
  defstruct resources: %{}, by_table: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    # Discover all modules with @exrest_resource attribute
    resources = discover_resources(opts[:otp_app])
    
    by_table = Map.new(resources, fn {_module, config} -> 
      {config.table, config.module} 
    end)
    
    {:ok, %__MODULE__{resources: resources, by_table: by_table}}
  end
  
  def get_resource(table) when is_binary(table) do
    GenServer.call(__MODULE__, {:get_by_table, table})
  end
  
  def get_resource(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:get_by_module, module})
  end
  
  def list_resources do
    GenServer.call(__MODULE__, :list)
  end

  # GenServer callbacks
  def handle_call({:get_by_table, table}, _from, state) do
    result = case Map.get(state.by_table, table) do
      nil -> {:error, :not_found}
      module -> {:ok, Map.get(state.resources, module)}
    end
    {:reply, result, state}
  end
  
  def handle_call({:get_by_module, module}, _from, state) do
    result = case Map.get(state.resources, module) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
    {:reply, result, state}
  end
  
  def handle_call(:list, _from, state) do
    {:reply, state.resources, state}
  end

  defp discover_resources(otp_app) do
    {:ok, modules} = :application.get_key(otp_app, :modules)
    
    modules
    |> Enum.filter(&exrest_resource?/1)
    |> Map.new(fn module ->
      {module, %{
        module: module,
        table: module.__schema__(:source),
        fields: module.__schema__(:fields),
        associations: module.__schema__(:associations),
        primary_key: module.__schema__(:primary_key)
      }}
    end)
  end
  
  defp exrest_resource?(module) do
    Code.ensure_loaded?(module) and
    function_exported?(module, :__schema__, 1) and
    Keyword.get(module.__info__(:attributes), :exrest_resource, [false]) |> List.first()
  end
end
```

### 2.4 Query Pipeline

The query pipeline composes filters from multiple sources:

```elixir
defmodule ExRest.QueryPipeline do
  @moduledoc """
  Builds and executes queries through the filter pipeline.
  """
  
  import Ecto.Query
  
  @doc """
  Execute a read query (GET).
  
  Pipeline:
  1. Base query from schema
  2. scope/2 callback (always runs)
  3. JSON permissions (if configured)
  4. URL filters (?status=eq.active)
  5. Custom params via handle_param/4
  6. Select, order, limit
  7. Execute
  8. after_load/2 callback
  """
  def execute_read(resource_module, params, context) do
    with {:ok, resource} <- ExRest.Registry.get_resource(resource_module),
         {:ok, parsed} <- ExRest.Parser.parse(params, resource) do
      
      resource.module
      |> base_query()
      |> resource.module.scope(context)
      |> apply_json_permissions(resource, context)
      |> apply_url_filters(parsed.filters, resource)
      |> apply_custom_params(resource.module, params, context)
      |> apply_select(parsed.select, resource)
      |> apply_order(parsed.order)
      |> apply_pagination(parsed.limit, parsed.offset)
      |> execute(context.repo)
      |> transform_results(resource.module, context)
    end
  end
  
  @doc """
  Execute a create (POST).
  """
  def execute_create(resource_module, attrs, context) do
    with {:ok, resource} <- ExRest.Registry.get_resource(resource_module),
         :ok <- check_insert_permission(resource, context) do
      
      struct(resource.module)
      |> resource.module.changeset(attrs, context)
      |> apply_column_presets(:insert, resource, context)
      |> context.repo.insert()
    end
  end
  
  @doc """
  Execute an update (PATCH).
  """
  def execute_update(resource_module, id, attrs, context) do
    with {:ok, resource} <- ExRest.Registry.get_resource(resource_module),
         {:ok, record} <- fetch_for_update(resource, id, context) do
      
      record
      |> resource.module.changeset(attrs, context)
      |> apply_column_presets(:update, resource, context)
      |> context.repo.update()
    end
  end
  
  @doc """
  Execute a delete (DELETE).
  """
  def execute_delete(resource_module, id, context) do
    with {:ok, resource} <- ExRest.Registry.get_resource(resource_module),
         {:ok, record} <- fetch_for_delete(resource, id, context) do
      context.repo.delete(record)
    end
  end

  # Private functions
  
  defp base_query(module) do
    from(r in module)
  end
  
  defp apply_json_permissions(query, resource, context) do
    case ExRest.Permissions.get_filter(resource.table, context.role, :select) do
      nil -> query
      filter -> ExRest.Permissions.apply_filter(query, filter, context)
    end
  end
  
  defp apply_url_filters(query, [], _resource), do: query
  defp apply_url_filters(query, filters, resource) do
    Enum.reduce(filters, query, fn filter, q ->
      ExRest.Filter.apply(q, filter, resource)
    end)
  end
  
  defp apply_custom_params(query, module, params, context) do
    # Filter out standard PostgREST params
    custom = Map.drop(params, ~w(select order limit offset on_conflict columns))
    
    Enum.reduce(custom, query, fn {key, value}, q ->
      module.handle_param(key, value, q, context)
    end)
  end
  
  defp apply_select(query, nil, _resource), do: query
  defp apply_select(query, select_ast, resource) do
    ExRest.Select.apply(query, select_ast, resource)
  end
  
  defp apply_order(query, nil), do: query
  defp apply_order(query, order_ast) do
    ExRest.Order.apply(query, order_ast)
  end
  
  defp apply_pagination(query, limit, offset) do
    query
    |> then(fn q -> if limit, do: limit(q, ^limit), else: q end)
    |> then(fn q -> if offset, do: offset(q, ^offset), else: q end)
  end
  
  defp execute(query, repo) do
    repo.all(query)
  end
  
  defp transform_results(records, module, context) do
    Enum.map(records, &module.after_load(&1, context))
  end
  
  defp fetch_for_update(resource, id, context) do
    query = base_query(resource.module)
      |> resource.module.scope(context)
      |> apply_json_permissions(resource, context)
      |> where([r], r.id == ^id)
    
    case context.repo.one(query) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end
  
  defp fetch_for_delete(resource, id, context) do
    # Same as update but checks delete permission
    with {:ok, record} <- fetch_for_update(resource, id, context),
         :ok <- check_delete_permission(resource, record, context) do
      {:ok, record}
    end
  end
end
```

### 2.5 Filter Application

Converting PostgREST/Hasura filters to Ecto queries:

```elixir
defmodule ExRest.Filter do
  @moduledoc """
  Applies parsed filters to Ecto queries.
  """
  
  import Ecto.Query
  
  @doc """
  Apply a single filter to a query.
  """
  def apply(query, %{field: field, operator: op, value: value}, resource) do
    # Field is already validated against schema at parse time
    field_atom = String.to_existing_atom(field)
    
    case op do
      :eq -> where(query, [r], field(r, ^field_atom) == ^value)
      :neq -> where(query, [r], field(r, ^field_atom) != ^value)
      :gt -> where(query, [r], field(r, ^field_atom) > ^value)
      :gte -> where(query, [r], field(r, ^field_atom) >= ^value)
      :lt -> where(query, [r], field(r, ^field_atom) < ^value)
      :lte -> where(query, [r], field(r, ^field_atom) <= ^value)
      :like -> where(query, [r], like(field(r, ^field_atom), ^value))
      :ilike -> where(query, [r], ilike(field(r, ^field_atom), ^value))
      :in -> where(query, [r], field(r, ^field_atom) in ^value)
      :is_null when value == true -> where(query, [r], is_nil(field(r, ^field_atom)))
      :is_null when value == false -> where(query, [r], not is_nil(field(r, ^field_atom)))
      :contains -> where(query, [r], fragment("? @> ?", field(r, ^field_atom), ^value))
      :contained_in -> where(query, [r], fragment("? <@ ?", field(r, ^field_atom), ^value))
      :fts -> where(query, [r], fragment("? @@ plainto_tsquery(?)", field(r, ^field_atom), ^value))
      
      # Plugin operators are handled via fragment
      {:plugin, plugin_module, op_spec} ->
        apply_plugin_operator(query, field_atom, value, plugin_module, op_spec)
    end
  end
  
  @doc """
  Apply logical grouping (_and, _or, _not).
  """
  def apply(query, %{logic: :and, conditions: conditions}, resource) do
    Enum.reduce(conditions, query, fn cond, q -> apply(q, cond, resource) end)
  end
  
  def apply(query, %{logic: :or, conditions: conditions}, resource) do
    dynamic = Enum.reduce(conditions, false, fn cond, acc ->
      cond_dynamic = build_dynamic(cond, resource)
      dynamic([r], ^acc or ^cond_dynamic)
    end)
    where(query, ^dynamic)
  end
  
  def apply(query, %{logic: :not, condition: condition}, resource) do
    cond_dynamic = build_dynamic(condition, resource)
    where(query, [r], not(^cond_dynamic))
  end
  
  defp build_dynamic(%{field: field, operator: op, value: value}, _resource) do
    field_atom = String.to_existing_atom(field)
    
    case op do
      :eq -> dynamic([r], field(r, ^field_atom) == ^value)
      :neq -> dynamic([r], field(r, ^field_atom) != ^value)
      :gt -> dynamic([r], field(r, ^field_atom) > ^value)
      :gte -> dynamic([r], field(r, ^field_atom) >= ^value)
      :lt -> dynamic([r], field(r, ^field_atom) < ^value)
      :lte -> dynamic([r], field(r, ^field_atom) <= ^value)
      :like -> dynamic([r], like(field(r, ^field_atom), ^value))
      :ilike -> dynamic([r], ilike(field(r, ^field_atom), ^value))
      :in -> dynamic([r], field(r, ^field_atom) in ^value)
      :is_null when value == true -> dynamic([r], is_nil(field(r, ^field_atom)))
      :is_null when value == false -> dynamic([r], not is_nil(field(r, ^field_atom)))
    end
  end
  
  defp apply_plugin_operator(query, field, value, plugin_module, op_spec) do
    case plugin_module.handle_filter(op_spec.name, field, value, %{}) do
      {:ok, {sql_fragment, params}} ->
        where(query, [r], fragment(^sql_fragment, ^params))
      :skip ->
        query
    end
  end
end
```

### 2.6 JSON Permissions (Optional Layer)

JSON permissions can be stored in a metadata table and applied automatically. ExRest uses **PostgREST-style operators by default** (`eq.`, `gt.`, etc.) but supports Hasura-style underscore operators (`_eq`, `_gt`) for backwards compatibility.

> **Hasura Metadata Compatibility:** ExRest permissions are designed to be compatible with Hasura's `hdb_metadata` permission format. If migrating from Hasura, you can import existing permission definitions with minimal changes. Both operator styles are fully supported and can be mixed.

```elixir
defmodule ExRest.Permissions do
  @moduledoc """
  Optional JSON permissions layer.
  
  Supports two operator syntaxes:
  - PostgREST-style (default): {"status": {"eq.": "active"}}
  - Hasura-style (compatible): {"status": {"_eq": "active"}}
  
  Both styles can be mixed and are fully interchangeable.
  """
  
  import Ecto.Query
  
  @doc """
  Get the filter for a table/role/action combination.
  Returns nil if no permission is configured (defaults to scope/2 only).
  """
  def get_filter(table, role, action) do
    case ExRest.PermissionsCache.get({table, role, action}) do
      {:ok, permission} -> permission["filter"]
      :not_found -> nil
    end
  end
  
  @doc """
  Apply a JSON filter expression to an Ecto query.
  
  PostgREST-style examples (recommended):
  - {"status": {"eq.": "active"}}
  - {"and": [{"status": {"eq.": "active"}}, {"total": {"gt.": 100}}]}
  - {"user_id": {"eq.": "X-ExRest-User-Id"}}
  
  Hasura-style examples (backwards compatible):
  - {"status": {"_eq": "active"}}
  - {"_and": [{"status": {"_eq": "active"}}, {"total": {"_gt": 100}}]}
  """
  def apply_filter(query, nil, _context), do: query
  def apply_filter(query, filter, context) when is_map(filter) do
    dynamic = build_permission_dynamic(filter, context)
    where(query, ^dynamic)
  end
  
  # Logical operators - support both PostgREST and Hasura styles
  @logical_and ["and", "_and"]
  @logical_or ["or", "_or"]
  @logical_not ["not", "_not"]
  
  defp build_permission_dynamic(filter, context) when is_map(filter) do
    cond do
      key = Enum.find(@logical_and, &Map.has_key?(filter, &1)) ->
        filter[key]
        |> Enum.map(&build_permission_dynamic(&1, context))
        |> Enum.reduce(fn d, acc -> dynamic([r], ^acc and ^d) end)
      
      key = Enum.find(@logical_or, &Map.has_key?(filter, &1)) ->
        filter[key]
        |> Enum.map(&build_permission_dynamic(&1, context))
        |> Enum.reduce(fn d, acc -> dynamic([r], ^acc or ^d) end)
      
      key = Enum.find(@logical_not, &Map.has_key?(filter, &1)) ->
        inner = build_permission_dynamic(filter[key], context)
        dynamic([r], not(^inner))
      
      true ->
        # Column filter: {"column": {"op": value}}
        filter
        |> Enum.map(fn {column, op_value} ->
          build_column_dynamic(column, op_value, context)
        end)
        |> Enum.reduce(fn d, acc -> dynamic([r], ^acc and ^d) end)
    end
  end
  
  # Operator mapping - PostgREST style (default) and Hasura style (compatible)
  @operators %{
    # PostgREST style (recommended)
    "eq." => :eq, "neq." => :neq,
    "gt." => :gt, "gte." => :gte,
    "lt." => :lt, "lte." => :lte,
    "like." => :like, "ilike." => :ilike,
    "in." => :in, "is." => :is_null,
    # Hasura style (backwards compatible)
    "_eq" => :eq, "_neq" => :neq,
    "_gt" => :gt, "_gte" => :gte,
    "_lt" => :lt, "_lte" => :lte,
    "_like" => :like, "_ilike" => :ilike,
    "_in" => :in, "_is_null" => :is_null
  }
  
  defp build_column_dynamic(column, op_value, context) when is_map(op_value) do
    field_atom = String.to_existing_atom(column)
    
    [{op, raw_value}] = Map.to_list(op_value)
    value = resolve_session_variable(raw_value, context)
    op_atom = Map.fetch!(@operators, op)
    
    case op_atom do
      :eq -> dynamic([r], field(r, ^field_atom) == ^value)
      :neq -> dynamic([r], field(r, ^field_atom) != ^value)
      :gt -> dynamic([r], field(r, ^field_atom) > ^value)
      :gte -> dynamic([r], field(r, ^field_atom) >= ^value)
      :lt -> dynamic([r], field(r, ^field_atom) < ^value)
      :lte -> dynamic([r], field(r, ^field_atom) <= ^value)
      :like -> dynamic([r], like(field(r, ^field_atom), ^value))
      :ilike -> dynamic([r], ilike(field(r, ^field_atom), ^value))
      :in -> dynamic([r], field(r, ^field_atom) in ^value)
      :is_null when value == true -> dynamic([r], is_nil(field(r, ^field_atom)))
      :is_null when value == false -> dynamic([r], not is_nil(field(r, ^field_atom)))
    end
  end
  
  # Resolve session variables from context
  defp resolve_session_variable("X-ExRest-User-Id", ctx), do: ctx.user_id
  defp resolve_session_variable("X-ExRest-Role", ctx), do: ctx.role
  defp resolve_session_variable("X-ExRest-Tenant-Id", ctx), do: ctx.tenant_id
  defp resolve_session_variable("X-Hasura-User-Id", ctx), do: ctx.user_id
  defp resolve_session_variable("X-Hasura-Role", ctx), do: ctx.role
  defp resolve_session_variable(value, _ctx), do: value
end
```

**Permissions Table Schema:**

```sql
CREATE TABLE ex_rest.permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name TEXT NOT NULL,
  role TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('select', 'insert', 'update', 'delete')),
  
  -- Permission filter (PostgREST or Hasura operator syntax supported)
  filter JSONB,           -- Row filter (WHERE clause)
  columns TEXT[],         -- Allowed columns (null = all)
  check JSONB,            -- Validation for insert/update
  set JSONB,              -- Column presets
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(table_name, role, action)
);

-- Example: Users can only see their own orders (PostgREST style - recommended)
INSERT INTO ex_rest.permissions (table_name, role, action, filter, columns) VALUES
('orders', 'user', 'select', '{"user_id": {"eq.": "X-ExRest-User-Id"}}', ARRAY['id', 'reference', 'status', 'total', 'inserted_at']),
('orders', 'user', 'insert', null, ARRAY['reference', 'shipping_address_id']),
('orders', 'user', 'update', '{"and": [{"user_id": {"eq.": "X-ExRest-User-Id"}}, {"status": {"eq.": "pending"}}]}', ARRAY['shipping_address_id']),
('orders', 'user', 'delete', null, null);  -- No delete permission (empty filter = denied)

-- Admins can do everything  
INSERT INTO ex_rest.permissions (table_name, role, action, filter, columns) VALUES
('orders', 'admin', 'select', null, null),
('orders', 'admin', 'insert', null, null),
('orders', 'admin', 'update', null, null),
('orders', 'admin', 'delete', null, null);
```

### 2.7 URL Filter Parser

Parses PostgREST-style URL parameters into filter AST:

```elixir
defmodule ExRest.Parser do
  @moduledoc """
  Parses PostgREST-style URL query parameters.
  """
  
  @reserved_params ~w(select order limit offset on_conflict columns count)
  
  def parse(params, resource) do
    with {:ok, select} <- parse_select(params["select"], resource),
         {:ok, order} <- parse_order(params["order"], resource),
         {:ok, filters} <- parse_filters(params, resource),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, offset} <- parse_offset(params["offset"]) do
      {:ok, %{
        select: select,
        order: order,
        filters: filters,
        limit: limit,
        offset: offset
      }}
    end
  end
  
  defp parse_filters(params, resource) do
    filters = params
      |> Map.drop(@reserved_params)
      |> Enum.flat_map(fn {key, value} ->
        parse_filter_param(key, value, resource)
      end)
    
    {:ok, filters}
  rescue
    e -> {:error, {:invalid_filter, e.message}}
  end
  
  defp parse_filter_param(key, value, resource) do
    cond do
      # Logical operators: and=(status.eq.active,total.gt.100)
      key in ["and", "or"] ->
        [parse_logical(key, value, resource)]
      
      # Negation: not.status.eq.active
      String.starts_with?(key, "not.") ->
        inner = parse_filter_param(String.trim_leading(key, "not."), value, resource)
        [%{logic: :not, condition: List.first(inner)}]
      
      # Column filter: status=eq.active
      true ->
        [parse_column_filter(key, value, resource)]
    end
  end
  
  defp parse_column_filter(column, value, resource) do
    # Validate column exists in schema
    unless column in Enum.map(resource.fields, &to_string/1) do
      raise "Unknown column: #{column}"
    end
    
    # Parse operator and value: "eq.active" -> {:eq, "active"}
    {operator, parsed_value} = parse_operator_value(value)
    
    %{field: column, operator: operator, value: parsed_value}
  end
  
  @operators %{
    "eq" => :eq, "neq" => :neq,
    "gt" => :gt, "gte" => :gte,
    "lt" => :lt, "lte" => :lte,
    "like" => :like, "ilike" => :ilike,
    "in" => :in, "is" => :is_null,
    "cs" => :contains, "cd" => :contained_in,
    "fts" => :fts, "plfts" => :plfts, "phfts" => :phfts
  }
  
  defp parse_operator_value(value) do
    case String.split(value, ".", parts: 2) do
      [op, rest] when is_map_key(@operators, op) ->
        {@operators[op], parse_value(rest, @operators[op])}
      
      # Check plugin operators
      [op, rest] ->
        case ExRest.PluginRegistry.get_operator(op) do
          {module, spec} -> {{:plugin, module, spec}, parse_value(rest, :string)}
          nil -> raise "Unknown operator: #{op}"
        end
    end
  end
  
  defp parse_value(value, :in) do
    # in.(1,2,3) -> [1, 2, 3]
    value
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",")
  end
  
  defp parse_value("null", :is_null), do: true
  defp parse_value("true", _), do: true
  defp parse_value("false", _), do: false
  defp parse_value(value, _), do: value  # Ecto handles type coercion
  
  defp parse_select(nil, _resource), do: {:ok, nil}
  defp parse_select(select_str, resource) do
    # Parse: "id,name,items(id,product_name)"
    ExRest.Parser.Select.parse(select_str, resource)
  end
  
  defp parse_order(nil, _resource), do: {:ok, nil}
  defp parse_order(order_str, resource) do
    # Parse: "inserted_at.desc,id.asc"
    ExRest.Parser.Order.parse(order_str, resource)
  end
  
  defp parse_limit(nil), do: {:ok, nil}
  defp parse_limit(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_limit}
    end
  end
  
  defp parse_offset(nil), do: {:ok, nil}
  defp parse_offset(offset) do
    case Integer.parse(offset) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_offset}
    end
  end
end
```

### 2.8 Associations & Embedded Resources

Handling `?select=id,name,items(id,product_name)`:

```elixir
defmodule ExRest.Select do
  @moduledoc """
  Handles select and embedded resource loading.
  """
  
  import Ecto.Query
  
  def apply(query, nil, _resource), do: query
  def apply(query, select_ast, resource) do
    {fields, embeds} = partition_select(select_ast, resource)
    
    query
    |> select_fields(fields)
    |> preload_embeds(embeds)
  end
  
  defp partition_select(select_ast, resource) do
    Enum.split_with(select_ast, fn
      %{type: :field} -> true
      %{type: :embed} -> false
    end)
  end
  
  defp select_fields(query, []), do: query
  defp select_fields(query, fields) do
    field_atoms = Enum.map(fields, fn %{name: name} ->
      String.to_existing_atom(name)
    end)
    
    select(query, [r], struct(r, ^field_atoms))
  end
  
  defp preload_embeds(query, []), do: query
  defp preload_embeds(query, embeds) do
    preloads = Enum.map(embeds, fn %{name: name, fields: fields} ->
      assoc_atom = String.to_existing_atom(name)
      
      if fields do
        field_atoms = Enum.map(fields, &String.to_existing_atom/1)
        {assoc_atom, from(a in subquery(select(a, ^field_atoms)))}
      else
        assoc_atom
      end
    end)
    
    preload(query, ^preloads)
  end
end
```

### 2.9 Phoenix Integration

```elixir
defmodule ExRest.Plug do
  @moduledoc """
  Phoenix Plug for ExRest API endpoints.
  """
  
  import Plug.Conn
  
  def init(opts) do
    %{
      repo: Keyword.fetch!(opts, :repo),
      prefix: Keyword.get(opts, :prefix, "/api"),
      json_library: Keyword.get(opts, :json, Jason)
    }
  end
  
  def call(%{path_info: path_info} = conn, opts) do
    case match_resource(path_info, opts.prefix) do
      {:ok, table, id} ->
        handle_request(conn, table, id, opts)
      :no_match ->
        conn
    end
  end
  
  defp match_resource(path_info, prefix) do
    prefix_parts = String.split(prefix, "/", trim: true)
    
    case path_info do
      ^prefix_parts ++ [table] -> {:ok, table, nil}
      ^prefix_parts ++ [table, id] -> {:ok, table, id}
      _ -> :no_match
    end
  end
  
  defp handle_request(conn, table, id, opts) do
    with {:ok, resource} <- ExRest.Registry.get_resource(table),
         {:ok, context} <- build_context(conn, opts) do
      
      result = case {conn.method, id} do
        {"GET", nil} -> execute_list(resource, conn.query_params, context)
        {"GET", id} -> execute_get(resource, id, conn.query_params, context)
        {"POST", nil} -> execute_create(resource, conn.body_params, context)
        {"PATCH", id} -> execute_update(resource, id, conn.body_params, context)
        {"DELETE", id} -> execute_delete(resource, id, context)
        _ -> {:error, :method_not_allowed}
      end
      
      send_response(conn, result, opts)
    else
      {:error, :not_found} ->
        send_error(conn, 404, "Resource not found", opts)
    end
  end
  
  defp build_context(conn, opts) do
    {:ok, %{
      repo: opts.repo,
      user_id: conn.assigns[:user_id],
      role: conn.assigns[:role] || "anonymous",
      tenant_id: conn.assigns[:tenant_id],
      assigns: conn.assigns
    }}
  end
  
  defp execute_list(resource, params, context) do
    ExRest.QueryPipeline.execute_read(resource.module, params, context)
  end
  
  defp execute_get(resource, id, params, context) do
    params_with_id = Map.put(params, "id", "eq.#{id}")
    
    case ExRest.QueryPipeline.execute_read(resource.module, params_with_id, context) do
      {:ok, [record]} -> {:ok, record}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end
  
  defp execute_create(resource, attrs, context) do
    ExRest.QueryPipeline.execute_create(resource.module, attrs, context)
  end
  
  defp execute_update(resource, id, attrs, context) do
    ExRest.QueryPipeline.execute_update(resource.module, id, attrs, context)
  end
  
  defp execute_delete(resource, id, context) do
    ExRest.QueryPipeline.execute_delete(resource, id, context)
  end
  
  defp send_response(conn, {:ok, data}, opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, opts.json_library.encode!(data))
    |> halt()
  end
  
  defp send_response(conn, {:error, :not_found}, opts) do
    send_error(conn, 404, "Not found", opts)
  end
  
  defp send_response(conn, {:error, changeset}, opts) when is_struct(changeset, Ecto.Changeset) do
    errors = format_changeset_errors(changeset)
    send_error(conn, 422, errors, opts)
  end
  
  defp send_error(conn, status, message, opts) do
    body = opts.json_library.encode!(%{error: message})
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
```

**Router Integration:**

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router
  
  pipeline :api do
    plug :accepts, ["json"]
    plug MyAppWeb.AuthPlug           # Sets user_id, role, tenant_id
    plug ExRest.Plug.RateLimiter     # Optional
  end
  
  scope "/api", MyAppWeb do
    pipe_through :api
    
    # ExRest handles all REST operations for registered resources
    forward "/", ExRest.Plug, repo: MyApp.Repo
  end
end
```

### 2.10 Caching Integration (Optional)

Optional per-resource caching with Nebulex. See Part 9.5 for configuration.

```elixir
defmodule ExRest.Cache do
  @moduledoc """
  Optional caching layer for ExRest queries.
  Only active when caching is enabled in config.
  """
  
  def get_or_execute(cache_key, ttl, fun) do
    if enabled?() do
      case ExRest.CacheAdapter.get(cache_key) do
        {:ok, cached} -> 
          {:ok, cached}
        {:error, :not_found} ->
          case fun.() do
            {:ok, result} ->
              ExRest.CacheAdapter.put(cache_key, result, ttl: ttl)
              {:ok, result}
            error ->
              error
          end
      end
    else
      fun.()
    end
  end
  
  def invalidate_resource(table) do
    if enabled?() do
      ExRest.CacheAdapter.delete_pattern("exrest:#{table}:*")
    end
  end
  
  def build_key(resource, params, context) do
    components = [
      resource.table,
      :erlang.phash2(params),
      context.role,
      context.user_id,
      context.tenant_id
    ]
    
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(components))
           |> Base.encode16(case: :lower)
           |> binary_part(0, 16)
    
    "exrest:#{resource.table}:#{hash}"
  end
  
  defp enabled?, do: Application.get_env(:ex_rest, [:cache, :enabled], false)
end
```

### 2.11 Project Structure

```
ex_rest/
├── lib/
│   ├── ex_rest.ex                        # Main API module
│   └── ex_rest/
│       ├── resource.ex                   # ExRest.Resource behavior
│       ├── registry.ex                   # Resource discovery & registry
│       ├── query_pipeline.ex             # Query execution pipeline
│       ├── parser/
│       │   ├── parser.ex                 # Main parser
│       │   ├── select.ex                 # Select clause parser
│       │   ├── order.ex                  # Order clause parser
│       │   └── filter.ex                 # Filter expression parser
│       ├── filter.ex                     # Filter application to Ecto
│       ├── select.ex                     # Select/preload application
│       ├── permissions.ex                # JSON permissions (optional)
│       ├── permissions_cache.ex          # Permissions caching
│       ├── plug.ex                       # Phoenix plug
│       ├── cache.ex                      # Query caching
│       ├── cache_adapter.ex              # Cache adapter behavior
│       ├── rate_limiter.ex               # Rate limiting behavior
│       └── plugins/
│           ├── plugin.ex                 # Plugin behavior
│           ├── postgis.ex                # PostGIS operators
│           ├── full_text_search.ex       # FTS operators
│           └── pgvector.ex               # pgvector operators
├── test/
│   ├── ex_rest_test.exs
│   ├── support/
│   │   ├── test_resources.ex             # Test schema modules
│   │   └── factory.ex                    # ExMachina factories
│   └── ex_rest/
│       ├── parser_test.exs
│       ├── filter_test.exs
│       ├── query_pipeline_test.exs
│       └── plug_test.exs
└── mix.exs
```

### 2.12 Implementation Phases

**Phase 1: Core Foundation**
- ExRest.Resource behavior
- Resource registry with compile-time discovery
- Basic query pipeline (scope, URL filters, execute)
- Phoenix plug with GET/POST/PATCH/DELETE

**Phase 2: Parser & Filters**
- PostgREST URL parameter parser
- Filter application with all standard operators
- Select clause with field selection
- Order and pagination

**Phase 3: Associations**
- Embedded resource parsing (?select=id,items(*))
- Ecto preload integration
- Nested filters on associations

**Phase 4: JSON Permissions (Optional Layer)**
- Permissions table schema
- Permission caching with NOTIFY/LISTEN
- Filter application from JSON permissions
- Column-level permissions

**Phase 5: Plugins**
- Plugin behavior and registry
- PostGIS plugin
- Full-text search plugin
- pgvector plugin

**Phase 6: Caching & Rate Limiting**
- Nebulex cache integration
- Cache key strategy
- Automatic invalidation on mutations
- Hammer rate limiting

**Phase 7: Production Hardening**
- Security headers
- Audit logging
- Error sanitization
- Multi-node support

**Phase 8: Compatibility Testing**
- Supabase client compatibility
- PostgREST URL compatibility
- Performance benchmarks

## Part 3: Comparison

### 3.1 Feature Comparison

| Feature | PostgREST | Hasura | ExRest |
|---------|-----------|--------|--------|
| **Resource Definition** | Schema introspection | Track tables in metadata | Ecto schemas (`use ExRest.Resource`) |
| **Table Exposure** | All in schema | Explicit tracking | Explicit schema modules |
| **Permissions** | PostgreSQL GRANT/RLS | JSON metadata | `scope/2` callback + optional JSON |
| **Custom Filters** | PostgreSQL functions | Computed fields | `handle_param/4` callback |
| **Mutations** | Raw SQL | GraphQL mutations | Ecto changesets |
| **Type Safety** | Runtime | Runtime | Compile-time (Ecto) |
| **Response Caching** | Not built-in | Not built-in | Optional Nebulex integration |
| **URL Compatibility** | Native | N/A | PostgREST-compatible |
| **Integration** | Standalone binary | Standalone service | Embedded in Phoenix |
| **Atom Safety** | N/A (Haskell) | N/A | Compile-time atoms |
| **Rate Limiting** | External | External | Optional Hammer integration |

### 3.2 Key Architectural Decisions

**Ecto Schemas Required (vs Database Introspection)**
- Explicit exposure - no accidental table leaks
- Compile-time type safety and atom safety
- Changeset validation for mutations
- Associations defined in code, not introspected
- Testable with Ecto sandbox

**scope/2 Callback (vs JSON-Only Permissions)**
- Full Elixir power for complex authorization
- Tenant isolation, soft deletes in code
- Composable Ecto queries
- Easy to test with standard ExUnit
- JSON permissions optional for runtime config

**handle_param/4 Callback (vs URL-Only Filtering)**
- Custom parameters like `?search=` or `?within_miles=`
- Full Ecto query composition
- Type-safe with pattern matching
- No need to define PostgreSQL functions

**Optional Nebulex Caching**
- Opt-in: disabled by default
- Pluggable: local, distributed, or multi-level
- Redis backend for multi-node
- Automatic invalidation on mutations
- Per-resource TTL configuration

**Optional Hammer Rate Limiting**
- Opt-in: disabled by default
- Pluggable adapters (ETS, Redis)
- Per-table, per-endpoint, per-role limits

### 3.3 When to Use Each

**Use PostgREST when:**
- You want zero-code API from existing database
- PostgreSQL GRANT/RLS is sufficient
- No Elixir/Phoenix in your stack
- Simplest possible setup

**Use Hasura when:**
- You need GraphQL, not REST
- You want subscriptions/real-time
- Managed service is appealing
- Complex relationships with single query

**Use ExRest when:**
- Building a Phoenix application
- Want PostgREST URL compatibility (Supabase clients)
- Need Elixir-level authorization logic (`scope/2`, `handle_param/4`)
- Want changeset validation on mutations
- Require compile-time type safety and atom safety
- Want optional caching/rate limiting with minimal setup

### 3.4 Migration from PostgREST

ExRest maintains URL compatibility. Existing Supabase clients work unchanged.

**Step 1: Define Resource Modules**

```elixir
# Instead of exposing via schema, define explicit resources
defmodule MyApp.API.Users do
  use ExRest.Resource
  import Ecto.Query
  
  schema "users" do
    field :name, :string
    field :email, :string
    field :role, :string
    timestamps()
  end
  
  def scope(query, _context) do
    where(query, [u], u.active == true)
  end
end
```

**Step 2: Add to Router**

```elixir
forward "/rest/v1", ExRest.Plug, repo: MyApp.Repo
```

**Step 3: Migrate Permissions**

PostgREST GRANT → ExRest scope/2:

```elixir
# PostgREST: GRANT SELECT ON users TO authenticated;
# ExRest:
def scope(query, %{role: "anonymous"}), do: none(query)  # No access
def scope(query, _context), do: query  # Authenticated users OK
```

PostgREST RLS → ExRest scope/2:

```elixir
# PostgREST RLS: user_id = current_setting('request.jwt.claims.sub')
# ExRest:
def scope(query, context) do
  where(query, [r], r.user_id == ^context.user_id)
end
```

**Step 4: Test with Existing Clients**

```javascript
// Supabase client works unchanged
const { data } = await supabase
  .from('users')
  .select('id, name, posts(*)')
  .eq('role', 'admin')
  .order('created_at', { ascending: false })
```

## Part 4: Security

This section documents the security model, attack vectors, and mitigations for ExRest.

### 4.0 Ecto-Provided Security

By requiring Ecto schemas, ExRest inherits significant security benefits:

| Threat | Raw SQL Risk | Ecto Mitigation |
|--------|--------------|-----------------|
| **SQL Injection** | String interpolation | Parameterized queries by default |
| **Atom Exhaustion** | `String.to_atom/1` from user input | Compile-time atoms from schema fields |
| **Type Confusion** | Manual type coercion | Ecto casting with schema types |
| **Mass Assignment** | All fields writable | Changeset `cast/3` allowlist |
| **Invalid Fields** | Runtime errors | Compile-time validation |

The remaining security concerns documented below focus on:
- JWT and session variable handling
- Permission bypass attempts  
- Cache poisoning
- Filter complexity attacks
- Error information leakage

### 4.1 Security Audit: Critical Issues & Fixes

#### 🔴 CRITICAL: Session Variable Resolution

**Problem:** The initial design resolved session variables from request headers, allowing header spoofing attacks:

```bash
# Attacker bypasses RLS by spoofing header
curl http://api.example.com/orders \
  -H "X-ExRest-User-Id: victim_user_id"
```

**Solution:** Session variables MUST come from verified JWT claims ONLY:

```elixir
# lib/ex_rest/security/session.ex
defmodule ExRest.Security.Session do
  @moduledoc """
  Secure session variable resolution from verified JWT claims.
  Session variables are NEVER resolved from raw headers - only from
  cryptographically verified JWT claims.
  """

  # Allowlist of session variables that can be resolved
  # This prevents atom exhaustion attacks
  @allowed_session_vars MapSet.new([
    "user_id", "user-id", "sub",
    "role", 
    "tenant_id", "tenant-id",
    "org_id", "org-id"
  ])

  @doc """
  Resolves a session variable from verified JWT claims.
  
  Supports multiple prefixes for compatibility:
  - X-ExRest-User-Id (ExRest native)
  - X-Hasura-User-Id (Hasura compatible)
  - request.jwt.claims.sub (PostgREST compatible)
  """
  def resolve(var_name, %{verified_claims: claims} = _context) do
    normalized = normalize_var_name(var_name)
    
    unless MapSet.member?(@allowed_session_vars, normalized) do
      raise ExRest.SecurityError, 
        "Unknown session variable: #{var_name}. " <>
        "Allowed: #{Enum.join(@allowed_session_vars, ", ")}"
    end
    
    case Map.get(claims, normalized) || Map.get(claims, var_name) do
      nil -> 
        raise ExRest.SecurityError,
          "Session variable '#{var_name}' not found in JWT claims"
      value -> 
        value
    end
  end

  def resolve(_var_name, _context) do
    raise ExRest.SecurityError,
      "Cannot resolve session variables without verified JWT claims"
  end

  # Normalize different prefix styles to canonical form
  defp normalize_var_name(name) do
    name
    |> String.replace(~r/^(X-ExRest-|X-Hasura-|x-exrest-|x-hasura-)/i, "")
    |> String.replace(~r/^request\.jwt\.(claims?\.)?/i, "")
    |> String.downcase()
    |> String.replace("-", "_")
  end
end
```

#### 🔴 CRITICAL: SQL Injection via Column Names

**Problem:** Column names were interpolated directly into SQL:

```elixir
# DANGEROUS - allows SQL injection
{~s("#{column}" = $#{idx}), [resolved], idx + 1}
```

**Solution:** Validate identifiers against schema cache and use proper quoting:

```elixir
# lib/ex_rest/security/identifier.ex
defmodule ExRest.Security.Identifier do
  @moduledoc """
  Secure identifier validation and quoting.
  Prevents SQL injection through column/table names.
  """

  # PostgreSQL reserved words that cannot be used as identifiers
  @reserved_words ~w(
    all analyse analyze and any array as asc asymmetric authorization
    between binary both case cast check collate collation column concurrently
    constraint create cross current_catalog current_date current_role
    current_schema current_time current_timestamp current_user default
    deferrable desc distinct do else end except false fetch for foreign
    freeze from full grant group having ilike in initially inner intersect
    into is isnull join lateral leading left like limit localtime
    localtimestamp natural not notnull null offset on only or order outer
    overlaps placing primary references returning right select session_user
    similar some symmetric table tablesample then to trailing true union
    unique user using variadic verbose when where window with
  ) |> MapSet.new()

  @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @doc """
  Validates and quotes a PostgreSQL identifier.
  Returns {:ok, quoted} or {:error, reason}.
  """
  def validate_and_quote(name, schema_cache \\ nil) do
    with :ok <- validate_format(name),
         :ok <- validate_not_reserved(name),
         :ok <- validate_in_schema(name, schema_cache) do
      {:ok, quote_identifier(name)}
    end
  end

  @doc """
  Validates identifier format.
  """
  def validate_format(name) when byte_size(name) > 63 do
    {:error, :identifier_too_long}
  end
  
  def validate_format(name) do
    if Regex.match?(@identifier_pattern, name) do
      :ok
    else
      {:error, :invalid_identifier_format}
    end
  end

  @doc """
  Checks if identifier is a reserved word.
  """
  def validate_not_reserved(name) do
    if String.downcase(name) in @reserved_words do
      {:error, :reserved_word}
    else
      :ok
    end
  end

  @doc """
  Validates identifier exists in schema cache (if provided).
  """
  def validate_in_schema(_name, nil), do: :ok
  
  def validate_in_schema(name, %{columns: columns}) do
    if Map.has_key?(columns, name) do
      :ok
    else
      {:error, :column_not_found}
    end
  end

  @doc """
  Properly quotes a PostgreSQL identifier.
  Escapes internal double quotes.
  """
  def quote_identifier(name) do
    escaped = String.replace(name, "\"", "\"\"")
    ~s("#{escaped}")
  end
end
```

#### 🔴 CRITICAL: Atom Exhaustion DoS

**Problem:** Dynamic conversion to atoms from user input:

```elixir
# DANGEROUS - allows atom table exhaustion
key = var_name |> String.to_atom()
```

**Solution:** Use `String.to_existing_atom/1` or string keys only:

```elixir
# lib/ex_rest/security/safe_map.ex
defmodule ExRest.Security.SafeMap do
  @moduledoc """
  Safe map operations that avoid atom creation from user input.
  """

  @doc """
  Gets a value from a map using string keys only.
  Never converts user input to atoms.
  """
  def get(map, key) when is_binary(key) do
    # Try string key first
    case Map.get(map, key) do
      nil -> 
        # Try existing atom if the map uses atom keys
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(map, atom_key)
        rescue
          ArgumentError -> nil
        end
      value -> 
        value
    end
  end

  def get(map, key), do: Map.get(map, key)
end
```

#### 🔴 CRITICAL: Admin API Authentication

**Problem:** Timing attacks on admin secret comparison.

**Solution:** Use constant-time comparison with rate limiting:

```elixir
# lib/ex_rest/admin/auth.ex
defmodule ExRest.Admin.Auth do
  @moduledoc """
  Secure authentication for admin API endpoints.
  """
  
  import Plug.Conn
  require Logger

  @max_auth_attempts 5
  @lockout_duration_ms 60_000

  def init(opts), do: opts

  def call(conn, opts) do
    admin_secret = Keyword.fetch!(opts, :admin_secret)
    
    with :ok <- check_rate_limit(conn),
         [provided_secret] <- get_req_header(conn, "x-admin-secret"),
         true <- Plug.Crypto.secure_compare(provided_secret, admin_secret) do
      assign(conn, :admin_authenticated, true)
    else
      _ ->
        # Add timing jitter to prevent timing attacks
        jitter = :rand.uniform(50)
        Process.sleep(100 + jitter)
        
        Logger.warning("Admin auth failed from #{get_client_ip(conn)}")
        
        conn
        |> put_status(401)
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end

  defp check_rate_limit(conn) do
    ip = get_client_ip(conn)
    bucket = "admin_auth:#{ip}"
    
    case Hammer.check_rate(bucket, @lockout_duration_ms, @max_auth_attempts) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end

  defp get_client_ip(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> List.first()
    |> case do
      nil -> conn.remote_ip |> :inet.ntoa() |> to_string()
      forwarded -> forwarded |> String.split(",") |> List.first() |> String.trim()
    end
  end
end
```

### 4.2 Cache Security: Preventing Cache Poisoning

**Problem:** Cache keys that don't include user context can leak data across users:

```elixir
# DANGEROUS - same cache for different users with same role
cache_key = {resource, :query, hash, role}
```

**Solution:** Include all permission-relevant context in cache keys:

```elixir
# lib/ex_rest/cache/secure_key.ex
defmodule ExRest.Cache.SecureKey do
  @moduledoc """
  Generates cryptographically secure cache keys that prevent
  cache poisoning attacks.
  """

  @doc """
  Builds a cache key that includes all permission-relevant context.
  Uses SHA-256 for collision resistance.
  """
  def build(resource, request, cache_config) do
    # Include ALL permission-relevant context
    permission_context = %{
      role: request.role,
      user_id: get_in(request, [:context, :verified_claims, "sub"]),
      tenant_id: get_in(request, [:context, :verified_claims, "tenant_id"])
    }
    
    query_fingerprint = %{
      resource: resource,
      permission_context: permission_context,
      select: normalize_select(request.select),
      filters: normalize_filters(request.filters),
      order: request.order,
      limit: request.limit,
      offset: request.offset
    }
    
    # Use cryptographic hash for collision resistance
    hash = 
      query_fingerprint
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)
    
    {resource, :query, hash, permission_context.role, permission_context.user_id}
  end

  defp normalize_select(nil), do: "*"
  defp normalize_select(select) when is_binary(select), do: select
  defp normalize_select(select) when is_list(select), do: Enum.sort(select)

  defp normalize_filters(nil), do: %{}
  defp normalize_filters(filters) when is_map(filters) do
    filters
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.into(%{})
  end
end
```

### 4.3 Mass Assignment Protection

**Problem:** Wildcard columns in mutations allow setting sensitive fields:

```elixir
# DANGEROUS - allows setting is_admin, role, etc.
if permission["columns"] == "*", do: :ok
```

**Solution:** Never allow wildcard columns for mutations, maintain blocklist:

```elixir
# lib/ex_rest/security/mass_assignment.ex
defmodule ExRest.Security.MassAssignment do
  @moduledoc """
  Prevents mass assignment attacks by validating mutation columns.
  Uses Ecto schema to determine allowed columns.
  """

  # Columns that can NEVER be written via API
  @never_writable MapSet.new([
    "id", "created_at", "updated_at", "deleted_at",
    "is_admin", "is_superuser", "role", "roles",
    "permissions", "password_hash", "password_digest",
    "encrypted_password", "api_key", "secret_key"
  ])

  @doc """
  Validates columns for insert/update operations.
  Uses Ecto schema fields as the source of truth.
  Returns {:ok, allowed_columns} or {:error, reason}.
  """
  def validate_columns(provided_columns, permission, schema_module) do
    provided = MapSet.new(provided_columns)
    
    # Check for globally forbidden columns
    forbidden = MapSet.intersection(provided, @never_writable)
    unless MapSet.size(forbidden) == 0 do
      return {:error, {:forbidden_columns, MapSet.to_list(forbidden)}}
    end
    
    # Get schema fields (Ecto provides these at compile-time)
    schema_fields = schema_module.__schema__(:fields)
                    |> Enum.map(&to_string/1)
                    |> MapSet.new()
    
    # Get allowed columns from permission (if using JSON permissions)
    # or default to schema fields minus protected columns
    allowed = case permission do
      nil -> 
        # No JSON permission - use changeset cast fields (defined in resource)
        MapSet.difference(schema_fields, @never_writable)
      
      %{"columns" => "*"} -> 
        # Wildcard - all schema fields minus protected
        MapSet.difference(schema_fields, @never_writable)
      
      %{"columns" => cols} when is_list(cols) -> 
        MapSet.new(cols)
      
      _ ->
        MapSet.difference(schema_fields, @never_writable)
    end
    
    extra = MapSet.difference(provided, allowed)
    if MapSet.size(extra) == 0 do
      {:ok, MapSet.to_list(provided)}
    else
      {:error, {:extra_columns, MapSet.to_list(extra)}}
    end
  end
end
```

> **Note:** In practice, Ecto's `cast/3` in changesets provides the primary protection against mass assignment. The changeset explicitly lists which fields can be written. This module provides an additional layer for JSON permission-based column restrictions.

### 4.4 Filter Complexity Limits

**Problem:** Unbounded filter nesting can cause DoS:

```elixir
# Attacker sends: 1000+ levels of nested _or/_and
{"_or": [{"_and": [{"_or": [...]}]}]}
```

**Solution:** Enforce depth and condition limits:

```elixir
# lib/ex_rest/security/filter_limits.ex
defmodule ExRest.Security.FilterLimits do
  @moduledoc """
  Enforces limits on filter complexity to prevent DoS attacks.
  """

  @max_depth 5
  @max_conditions 50

  defstruct [:depth, :condition_count]

  @doc """
  Validates filter complexity.
  Returns :ok or {:error, reason}.
  """
  def validate(filter) do
    case check_complexity(filter, 0, 0) do
      {:ok, _count} -> :ok
      {:error, _} = error -> error
    end
  end

  defp check_complexity(_, depth, _) when depth > @max_depth do
    {:error, {:filter_too_deep, @max_depth}}
  end

  defp check_complexity(_, _, count) when count > @max_conditions do
    {:error, {:too_many_conditions, @max_conditions}}
  end

  defp check_complexity(%{"_and" => conditions}, depth, count) when is_list(conditions) do
    check_condition_list(conditions, depth + 1, count)
  end

  defp check_complexity(%{"_or" => conditions}, depth, count) when is_list(conditions) do
    check_condition_list(conditions, depth + 1, count)
  end

  defp check_complexity(%{"_not" => condition}, depth, count) do
    check_complexity(condition, depth + 1, count + 1)
  end

  defp check_complexity(filter, depth, count) when is_map(filter) do
    new_count = count + map_size(filter)
    if new_count > @max_conditions do
      {:error, {:too_many_conditions, @max_conditions}}
    else
      {:ok, new_count}
    end
  end

  defp check_condition_list(conditions, depth, count) do
    Enum.reduce_while(conditions, {:ok, count}, fn cond, {:ok, acc_count} ->
      case check_complexity(cond, depth, acc_count + 1) do
        {:ok, new_count} -> {:cont, {:ok, new_count}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
```

### 4.5 Error Message Sanitization

**Problem:** Database error messages leak schema information:

```elixir
# DANGEROUS - exposes schema details
send_error(conn, 400, "Database error: #{postgres_error_message}")
```

**Solution:** Map errors to generic messages, log details internally:

```elixir
# lib/ex_rest/security/error_handler.ex
defmodule ExRest.Security.ErrorHandler do
  @moduledoc """
  Handles errors without leaking sensitive information.
  """
  require Logger

  @doc """
  Maps database errors to safe client responses.
  """
  def handle_db_error(%Postgrex.Error{postgres: %{code: code}} = error, conn) do
    # Log full details internally
    request_id = conn.assigns[:request_id] || "unknown"
    Logger.error(
      "Database error [#{request_id}]: #{inspect(error)}",
      request_id: request_id
    )

    # Return generic message to client
    {status, message} = case code do
      "42P01" -> {404, "Resource not found"}
      "42501" -> {403, "Access denied"}
      "23505" -> {409, "Conflict: duplicate entry"}
      "23503" -> {409, "Conflict: referenced record not found"}
      "22P02" -> {400, "Invalid input syntax"}
      "42703" -> {400, "Invalid column reference"}
      _ -> {500, "Internal server error"}
    end

    {status, %{error: message, request_id: request_id}}
  end

  @doc """
  Formats a safe error response.
  """
  def safe_error(status, message, request_id \\ nil) do
    body = case request_id do
      nil -> %{error: message}
      id -> %{error: message, request_id: id}
    end
    {status, body}
  end
end
```

### 4.6 Metadata Table Protection

**Problem:** The `ex_rest.metadata` table itself might be accessible via API:

```bash
# Attacker queries metadata to discover permissions
curl "http://api.example.com/ex_rest.metadata?select=*"
```

**Solution:** Hard-coded blocklist of system tables:

```elixir
# lib/ex_rest/security/table_access.ex
defmodule ExRest.Security.TableAccess do
  @moduledoc """
  Controls which tables can be accessed via the API.
  """

  @blocked_tables MapSet.new([
    "ex_rest.metadata",
    "ex_rest.audit_log",
    "schema_migrations",
    "ar_internal_metadata",
    "oban_jobs",
    "oban_peers"
  ])

  @blocked_schemas MapSet.new([
    "pg_catalog",
    "information_schema",
    "pg_toast"
  ])

  @doc """
  Validates that a table can be accessed.
  Returns :ok or {:error, :not_found} (never reveals existence).
  """
  def validate_access(schema, table) do
    qualified = "#{schema}.#{table}"
    
    cond do
      MapSet.member?(@blocked_schemas, schema) ->
        {:error, :not_found}
      MapSet.member?(@blocked_tables, qualified) ->
        {:error, :not_found}
      String.starts_with?(table, "pg_") ->
        {:error, :not_found}
      String.starts_with?(table, "_") ->
        {:error, :not_found}
      true ->
        :ok
    end
  end
end
```

---

## Part 5: Supabase Compatibility

ExRest maintains full compatibility with Supabase clients by supporting the same headers, JWT handling, and session variable patterns.

### 5.1 Header Compatibility

```elixir
# lib/ex_rest/plug/supabase_compat.ex
defmodule ExRest.Plug.SupabaseCompat do
  @moduledoc """
  Ensures compatibility with Supabase clients.
  
  Supported headers:
  - `apikey` - Supabase API key (used for service identification)
  - `Authorization: Bearer <jwt>` - User JWT for authentication
  - `Accept-Profile` / `Content-Profile` - Schema selection
  - `Prefer` - PostgREST preferences
  """
  
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> extract_api_key(opts)
    |> extract_jwt()
    |> extract_schema()
    |> extract_prefer_header()
  end

  # Supabase sends API key in `apikey` header
  defp extract_api_key(conn, opts) do
    anon_key = Keyword.get(opts, :anon_key)
    service_key = Keyword.get(opts, :service_role_key)

    case get_req_header(conn, "apikey") do
      [key] when key == service_key ->
        assign(conn, :api_key_role, :service_role)
      [key] when key == anon_key ->
        assign(conn, :api_key_role, :anon)
      [_key] ->
        assign(conn, :api_key_role, :unknown)
      [] ->
        assign(conn, :api_key_role, nil)
    end
  end

  # JWT comes in Authorization: Bearer header
  defp extract_jwt(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        assign(conn, :raw_jwt, token)
      _ ->
        conn
    end
  end

  # Schema selection via Accept-Profile/Content-Profile
  defp extract_schema(conn) do
    schema = 
      get_req_header(conn, "accept-profile")
      |> List.first()
      |> Kernel.||(get_req_header(conn, "content-profile") |> List.first())
    
    if schema do
      assign(conn, :target_schema, schema)
    else
      conn
    end
  end

  # PostgREST Prefer header
  defp extract_prefer_header(conn) do
    case get_req_header(conn, "prefer") do
      [prefer] -> assign(conn, :prefer_header, prefer)
      _ -> conn
    end
  end
end
```

### 5.2 JWT Verification and Role Switching

Like PostgREST, ExRest verifies JWTs and uses the claims for role switching and RLS context:

```elixir
# lib/ex_rest/auth/jwt.ex
defmodule ExRest.Auth.JWT do
  @moduledoc """
  JWT verification compatible with Supabase/PostgREST.
  
  Sets PostgreSQL session variables (GUCs) for RLS:
  - request.jwt.claims (full claims as JSON)
  - request.jwt.claim.{claim_name} (individual claims)
  """
  
  require Logger

  @clock_skew_seconds 30

  @doc """
  Verifies a JWT and extracts claims.
  """
  def verify(token, opts) do
    secret = Keyword.fetch!(opts, :jwt_secret)
    
    case JOSE.JWT.verify_strict(secret, ["HS256", "RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        with :ok <- validate_exp(claims),
             :ok <- validate_iat(claims),
             :ok <- validate_aud(claims, opts) do
          {:ok, claims}
        end
      {false, _, _} ->
        {:error, :invalid_signature}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts the role from JWT claims.
  Supports multiple claim paths for compatibility:
  - `.role` (PostgREST standard)
  - `.user_metadata.role` (Supabase Auth)
  - Custom path via `jwt_role_claim_key`
  """
  def extract_role(claims, opts \\ []) do
    role_claim_key = Keyword.get(opts, :jwt_role_claim_key, ".role")
    
    case get_claim_by_path(claims, role_claim_key) do
      nil -> Keyword.get(opts, :default_role, "anon")
      role -> role
    end
  end

  @doc """
  Generates SQL to set session variables for RLS.
  This is how PostgREST makes JWT claims available to RLS policies.
  """
  def set_session_sql(claims) do
    claims_json = Jason.encode!(claims)
    
    # Set full claims as JSON
    statements = [
      "SELECT set_config('request.jwt.claims', $1, true)",
    ]
    
    # Set individual claims
    individual_statements = 
      claims
      |> Enum.flat_map(fn {key, value} ->
        string_value = to_claim_string(value)
        ["SELECT set_config('request.jwt.claim.#{key}', '#{escape_sql_string(string_value)}', true)"]
      end)
    
    {Enum.join(statements ++ individual_statements, "; "), [claims_json]}
  end

  defp validate_exp(%{"exp" => exp}) do
    now = System.system_time(:second)
    if exp + @clock_skew_seconds >= now do
      :ok
    else
      {:error, :token_expired}
    end
  end
  defp validate_exp(_), do: :ok

  defp validate_iat(%{"iat" => iat}) do
    now = System.system_time(:second)
    if iat - @clock_skew_seconds <= now do
      :ok
    else
      {:error, :token_not_yet_valid}
    end
  end
  defp validate_iat(_), do: :ok

  defp validate_aud(claims, opts) do
    case Keyword.get(opts, :jwt_aud) do
      nil -> :ok
      expected_aud ->
        case Map.get(claims, "aud") do
          nil -> :ok
          ^expected_aud -> :ok
          aud when is_list(aud) ->
            if expected_aud in aud, do: :ok, else: {:error, :invalid_audience}
          _ -> {:error, :invalid_audience}
        end
    end
  end

  defp get_claim_by_path(claims, "." <> path) do
    path
    |> String.split(".")
    |> Enum.reduce(claims, fn key, acc ->
      case acc do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  defp to_claim_string(value) when is_binary(value), do: value
  defp to_claim_string(value) when is_number(value), do: to_string(value)
  defp to_claim_string(value) when is_boolean(value), do: to_string(value)
  defp to_claim_string(value), do: Jason.encode!(value)

  defp escape_sql_string(s), do: String.replace(s, "'", "''")
end
```

### 5.3 Session Variable Compatibility (Multi-Prefix Support)

Support both ExRest and Hasura session variable prefixes:

```elixir
# lib/ex_rest/metadata/filter_expression.ex (updated)
defmodule ExRest.Metadata.FilterExpression do
  @moduledoc """
  Evaluates Hasura-compatible boolean expressions.
  
  Supports session variable prefixes:
  - X-ExRest-User-Id (ExRest native)
  - X-Hasura-User-Id (Hasura compatible)
  - request.jwt.claims.sub (PostgREST compatible)
  
  Values starting with these prefixes are resolved from verified JWT claims.
  """

  @session_var_prefixes [
    ~r/^X-ExRest-/i,
    ~r/^X-Hasura-/i,
    ~r/^request\.jwt\.(claims?\.)?/i
  ]

  # ... (existing to_sql functions)

  @doc """
  Resolves a value, detecting session variables by prefix.
  Session variables are ONLY resolved from verified JWT claims.
  """
  def resolve_value(value, context) when is_binary(value) do
    if session_variable?(value) do
      ExRest.Security.Session.resolve(value, context)
    else
      case value do
        "now()" -> DateTime.utc_now()
        "current_timestamp" -> DateTime.utc_now()
        "gen_random_uuid()" -> Ecto.UUID.generate()
        _ -> value
      end
    end
  end
  
  def resolve_value(value, _context), do: value

  defp session_variable?(value) do
    Enum.any?(@session_var_prefixes, &Regex.match?(&1, value))
  end
end
```

### 5.4 PostgreSQL RLS Integration (Optional)

ExRest supports PostgreSQL RLS as an OPTIONAL additional security layer. The primary security comes from ExRest's application-level permissions:

```elixir
# lib/ex_rest/query/executor.ex
defmodule ExRest.Query.Executor do
  @moduledoc """
  Executes queries with proper security context.
  
  Security layers (in order):
  1. ExRest metadata permissions (always enforced)
  2. PostgreSQL RLS (optional, if enabled)
  
  PostgreSQL RLS is set up via:
  - SET ROLE for user impersonation
  - Session variables (GUCs) for RLS policies
  """

  alias ExRest.Auth.JWT

  @doc """
  Executes a query with full security context.
  """
  def execute(query, params, context, opts \\ []) do
    use_rls = Keyword.get(opts, :use_postgres_rls, false)
    
    Postgrex.transaction(context.conn, fn conn ->
      # Set session variables for RLS (even if RLS disabled, for consistency)
      if context.verified_claims do
        {set_sql, set_params} = JWT.set_session_sql(context.verified_claims)
        Postgrex.query!(conn, set_sql, set_params)
      end
      
      # Optional: Switch role for PostgreSQL RLS
      if use_rls and context.role do
        # Validate role name before using
        with {:ok, quoted_role} <- ExRest.Security.Identifier.validate_and_quote(context.role) do
          Postgrex.query!(conn, "SET LOCAL ROLE #{quoted_role}", [])
        end
      end
      
      # Execute the actual query
      Postgrex.query!(conn, query, params)
    end)
  end
end
```

---

## Part 6: Performance

ExRest leverages PostgreSQL's native JSON functions for optimal performance. While the core architecture uses Ecto, performance-critical JSON generation may use raw SQL fragments for maximum efficiency.

> **Note:** The patterns below show the generated SQL. In practice, ExRest uses Ecto's `fragment/1` macro to embed these PostgreSQL-native JSON operations within Ecto queries, maintaining type safety while achieving optimal performance.

### 6.1 Performance Benefits

PostgreSQL's native JSON functions (`json_agg`, `json_build_object`, `row_to_json`) are significantly faster than application-level JSON serialization because:

1. **No data transfer overhead** - JSON is built where the data lives
2. **Streaming results** - Single column result vs. multiple columns
3. **Less memory** - No intermediate data structures in Elixir

Benchmarks show **3-5x throughput improvement** for nested/embedded queries.

### 6.2 JSON Generation Patterns

```elixir
# lib/ex_rest/query/json_builder.ex
defmodule ExRest.Query.JsonBuilder do
  @moduledoc """
  Generates SQL that produces JSON output using PostgreSQL native functions.
  
  Uses:
  - json_build_object() for explicit column selection (most efficient)
  - json_agg() for array aggregation
  - row_to_json() for full row conversion
  - COALESCE for null handling
  """

  @doc """
  Builds a SELECT that returns JSON directly.
  
  ## Examples
  
      build_json_select(["id", "name"], "users", nil)
      # => SELECT json_agg(json_build_object('id', "id", 'name', "name")) FROM "users"
      
      build_json_select(["id", "name", {:embed, "posts", ["id", "title"]}], "users", nil)
      # => SELECT json_agg(json_build_object(
      #      'id', "id",
      #      'name', "name", 
      #      'posts', (SELECT COALESCE(json_agg(...), '[]') FROM posts WHERE ...)
      #    )) FROM "users"
  """
  def build_json_select(columns, table, where_clause, opts \\ []) do
    json_obj = build_json_object(columns, table)
    
    base = """
    SELECT COALESCE(json_agg(_exrest_row), '[]'::json) AS data
    FROM (
      SELECT #{json_obj} AS _exrest_row
      FROM #{quote_table(table)}
      #{where_clause || ""}
      #{build_order_clause(opts[:order])}
      #{build_limit_clause(opts[:limit])}
      #{build_offset_clause(opts[:offset])}
    ) _exrest_subq
    """
    
    String.trim(base)
  end

  @doc """
  Builds a json_build_object expression for columns.
  """
  def build_json_object(columns, parent_table) do
    args = 
      columns
      |> Enum.flat_map(fn
        {:embed, rel_name, rel_columns, rel_config} ->
          ["'#{rel_name}'", build_embed_subquery(rel_name, rel_columns, rel_config, parent_table)]
        
        {:alias, alias_name, actual_column} ->
          ["'#{alias_name}'", quote_column(actual_column)]
        
        {:json_path, path, alias_name} ->
          ["'#{alias_name}'", path]
        
        column when is_binary(column) ->
          ["'#{column}'", quote_column(column)]
      end)
      |> Enum.join(", ")
    
    "json_build_object(#{args})"
  end

  @doc """
  Builds a subquery for embedded resources (relationships).
  """
  def build_embed_subquery(rel_name, columns, rel_config, parent_table) do
    fk_column = rel_config[:foreign_key] || "#{singularize(parent_table)}_id"
    pk_column = rel_config[:primary_key] || "id"
    
    inner_json = build_json_object(columns, rel_name)
    
    """
    (SELECT COALESCE(json_agg(#{inner_json}), '[]'::json)
     FROM #{quote_table(rel_name)}
     WHERE #{quote_column(fk_column)} = #{quote_table(parent_table)}.#{quote_column(pk_column)})
    """
  end

  @doc """
  Builds SQL for a single row response.
  """
  def build_single_json_select(columns, table, where_clause) do
    json_obj = build_json_object(columns, table)
    
    """
    SELECT #{json_obj} AS data
    FROM #{quote_table(table)}
    #{where_clause}
    LIMIT 1
    """
  end

  @doc """
  Builds aggregation queries (COUNT, SUM, etc.) with JSON output.
  """
  def build_aggregate_select(aggregates, table, where_clause) do
    agg_exprs = 
      aggregates
      |> Enum.map(fn
        {:count, "*"} -> "'count', COUNT(*)"
        {:count, col} -> "'count_#{col}', COUNT(#{quote_column(col)})"
        {:sum, col} -> "'sum_#{col}', SUM(#{quote_column(col)})"
        {:avg, col} -> "'avg_#{col}', AVG(#{quote_column(col)})"
        {:min, col} -> "'min_#{col}', MIN(#{quote_column(col)})"
        {:max, col} -> "'max_#{col}', MAX(#{quote_column(col)})"
      end)
      |> Enum.join(", ")
    
    """
    SELECT json_build_object(#{agg_exprs}) AS data
    FROM #{quote_table(table)}
    #{where_clause}
    """
  end

  # Helper functions
  defp quote_table(name), do: ~s("#{name}")
  defp quote_column(name), do: ~s("#{name}")
  
  defp build_order_clause(nil), do: ""
  defp build_order_clause(order), do: "ORDER BY #{order}"
  
  defp build_limit_clause(nil), do: ""
  defp build_limit_clause(n), do: "LIMIT #{n}"
  
  defp build_offset_clause(nil), do: ""
  defp build_offset_clause(n), do: "OFFSET #{n}"
  
  defp singularize(name) do
    cond do
      String.ends_with?(name, "ies") -> 
        String.replace_suffix(name, "ies", "y")
      String.ends_with?(name, "es") -> 
        String.replace_suffix(name, "es", "")
      String.ends_with?(name, "s") -> 
        String.replace_suffix(name, "s", "")
      true -> 
        name
    end
  end
end
```

### 6.3 Example Generated Queries

**Simple SELECT:**
```sql
-- Request: GET /users?select=id,name,email
SELECT COALESCE(json_agg(_exrest_row), '[]'::json) AS data
FROM (
  SELECT json_build_object('id', "id", 'name', "name", 'email', "email") AS _exrest_row
  FROM "users"
) _exrest_subq
```

**With Embedded Relationship:**
```sql
-- Request: GET /users?select=id,name,posts(id,title)
SELECT COALESCE(json_agg(_exrest_row), '[]'::json) AS data
FROM (
  SELECT json_build_object(
    'id', "id",
    'name', "name",
    'posts', (
      SELECT COALESCE(json_agg(
        json_build_object('id', "id", 'title', "title")
      ), '[]'::json)
      FROM "posts"
      WHERE "user_id" = "users"."id"
    )
  ) AS _exrest_row
  FROM "users"
) _exrest_subq
```

**With Filtering and Ordering:**
```sql
-- Request: GET /users?select=id,name&status=eq.active&order=created_at.desc&limit=10
SELECT COALESCE(json_agg(_exrest_row), '[]'::json) AS data
FROM (
  SELECT json_build_object('id', "id", 'name', "name") AS _exrest_row
  FROM "users"
  WHERE "status" = $1
  ORDER BY "created_at" DESC
  LIMIT 10
) _exrest_subq

-- Parameters: ["active"]
```

### 6.4 Response Streaming

For large responses, ExRest can stream JSON directly from PostgreSQL:

```elixir
# lib/ex_rest/query/streaming.ex
defmodule ExRest.Query.Streaming do
  @moduledoc """
  Streams large query results directly to the client.
  Uses PostgreSQL cursors for memory efficiency.
  """

  @doc """
  Executes a query and streams results as NDJSON (newline-delimited JSON).
  """
  def stream_ndjson(conn, query, params, context) do
    conn = 
      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_chunked(200)
    
    Postgrex.transaction(context.db_conn, fn db_conn ->
      # Set up cursor
      Postgrex.query!(db_conn, "DECLARE _exrest_cursor CURSOR FOR #{query}", params)
      
      stream_cursor(conn, db_conn)
    end)
    
    conn
  end

  defp stream_cursor(conn, db_conn) do
    case Postgrex.query!(db_conn, "FETCH 100 FROM _exrest_cursor", []) do
      %{rows: []} ->
        :ok
      %{rows: rows} ->
        chunks = 
          rows
          |> Enum.map(fn [json] -> json <> "\n" end)
          |> Enum.join("")
        
        {:ok, conn} = Plug.Conn.chunk(conn, chunks)
        stream_cursor(conn, db_conn)
    end
  end
end
```

---

## Part 7: Operational Security

### 7.1 Response Security Headers

```elixir
# lib/ex_rest/plug/security_headers.ex
defmodule ExRest.Plug.SecurityHeaders do
  @moduledoc """
  Adds security headers to all responses.
  """
  
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = generate_request_id()
    
    conn
    |> assign(:request_id, request_id)
    |> put_resp_header("x-request-id", request_id)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("content-security-policy", "default-src 'none'")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-exrest-version", ExRest.version())
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

### 7.2 Audit Logging

```elixir
# lib/ex_rest/audit/logger.ex
defmodule ExRest.Audit.Logger do
  @moduledoc """
  Audit logging for security-sensitive operations.
  """
  require Logger

  def log_request(conn, action, result) do
    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      request_id: conn.assigns[:request_id],
      action: action,
      table: conn.path_params["table"],
      method: conn.method,
      role: conn.assigns[:role],
      user_id: get_in(conn.assigns, [:verified_claims, "sub"]),
      ip: get_client_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      result: result,
      duration_ms: conn.assigns[:duration_ms]
    }

    Logger.info(Jason.encode!(entry))
    
    # Optionally write to database
    if Application.get_env(:ex_rest, :audit_to_database, false) do
      write_audit_log(entry)
    end
  end

  defp get_client_ip(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> List.first()
    |> case do
      nil -> conn.remote_ip |> :inet.ntoa() |> to_string()
      forwarded -> forwarded |> String.split(",") |> List.first() |> String.trim()
    end
  end

  defp write_audit_log(entry) do
    # Write to ex_rest.audit_log table
    # Implementation depends on your setup
  end
end
```

### 7.3 Rate Limiting

```elixir
# lib/ex_rest/plug/rate_limiter.ex  
defmodule ExRest.Plug.RateLimiter do
  @moduledoc """
  Rate limiting using Hammer.
  """
  
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    max_requests = Keyword.get(opts, :max_requests, 100)
    window_ms = Keyword.get(opts, :window_ms, 60_000)
    
    key = rate_limit_key(conn, opts)
    
    case Hammer.check_rate(key, window_ms, max_requests) do
      {:allow, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", to_string(max_requests - count))
        
      {:deny, _limit} ->
        conn
        |> put_resp_header("retry-after", to_string(div(window_ms, 1000)))
        |> send_resp(429, Jason.encode!(%{error: "Too many requests"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn, opts) do
    key_func = Keyword.get(opts, :key_func, &default_key/1)
    key_func.(conn)
  end

  defp default_key(conn) do
    # Rate limit by user_id if authenticated, otherwise by IP
    user_id = get_in(conn.assigns, [:verified_claims, "sub"])
    
    if user_id do
      "exrest:user:#{user_id}"
    else
      ip = conn.remote_ip |> :inet.ntoa() |> to_string()
      "exrest:ip:#{ip}"
    end
  end
end
```

---

### 4.7 Deployment Checklist

Before deploying ExRest, ensure:

**Required:**
- [ ] **JWT secret** is at least 256 bits and stored securely
- [ ] **TLS** is enforced on all connections
- [ ] **CORS** is properly configured for allowed origins
- [ ] **Filter complexity limits** are appropriate for your use case
- [ ] Ecto schemas define only intended public resources

**Recommended:**
- [ ] **Admin secret** (if using admin API) is strong and only accessible to trusted systems
- [ ] **Audit logging** is enabled for sensitive operations
- [ ] **PostgreSQL permissions** are configured as defense-in-depth

**Optional (enable as needed):**
- [ ] **Rate limiting** is configured for public-facing endpoints
- [ ] **Caching** is configured with appropriate TTLs
- [ ] **JSON permissions** are configured for runtime role-based access


## Part 8: Future Considerations

This section documents additional considerations for future development phases.

### 8.1 Operational / DevOps

**Connection Pooling Strategy**
- How does ExRest interact with Ecto's connection pool vs. dedicated Postgrex pools?
- Should permission-heavy queries get separate pool to avoid blocking?
- Connection pool sizing for high-concurrency scenarios

**Health Checks & Readiness**
- `/health` endpoint that verifies metadata table connectivity
- `/ready` that confirms schema cache is warm
- Kubernetes liveness/readiness probe patterns

**Graceful Degradation**
- What happens if metadata table is temporarily unavailable?
- Should there be a fallback to cached metadata on disk?
- Circuit breaker patterns for database connectivity

**Blue/Green Deployments**
- Metadata schema migrations during zero-downtime deploys
- Version compatibility between ExRest versions and metadata schema


### 8.2 Additional Security Considerations

**Row-Level Encryption**
- Supporting encrypted columns (pgcrypto) transparently
- Key management integration (Vault, AWS KMS)

**Audit Trail Requirements**
- SOC2/HIPAA compliance - immutable audit logs
- What gets logged vs. what's too sensitive to log (PII in filters?)

**API Key Authentication**
- Beyond JWT - supporting API keys for service-to-service
- Key rotation without downtime

**Request Signing**
- HMAC request signing for webhook-style integrations
- Replay attack prevention (nonce/timestamp validation)

**Content Security**
- Input size limits per endpoint (not just global)
- File upload handling if using bytea columns
- SQL function injection via RPC endpoints


### 8.3 Performance Optimizations

**Query Plan Caching**
- PostgreSQL prepared statements for repeated query patterns
- When to use vs. when dynamic SQL is better

**Batch Operations**
- Bulk INSERT performance (COPY vs. multi-row INSERT)
- Batch UPDATE/DELETE with RETURNING optimization

**Pagination Strategies**
- Cursor-based pagination for large datasets (keyset pagination)
- Offset pagination performance cliff warnings
- `Range` header support like PostgREST

**Read Replicas**
- Routing read queries to replicas
- Consistency guarantees (read-your-writes)
- Replica lag detection

**Response Compression**
- gzip/brotli for large JSON responses
- Conditional compression based on response size


### 8.4 Developer Experience

**Debugging Tools**
- Query explain mode (`?explain=true` returning EXPLAIN ANALYZE)
- Debug headers showing cache hit/miss, query time, permission evaluation
- Request tracing with OpenTelemetry

**SDK Generation**
- OpenAPI spec generation from metadata
- TypeScript type generation for tracked tables
- GraphQL schema generation (future consideration?)

**Local Development**
- Docker Compose setup with ExRest + Postgres
- Seed data management for permissions testing
- Hot reload of metadata during development

**Error Messages**
- Developer-friendly errors in dev mode vs. sanitized in prod
- Error codes that map to documentation
- Suggested fixes in error responses


### 8.5 Compatibility Edge Cases

**PostgREST Quirks to Match**
- Exact error response format (JSON structure, HTTP codes)
- Header casing (case-insensitive handling)
- Empty array vs. null for no results
- `Prefer: return=representation` exact behavior

**Supabase-Specific**
- Realtime integration considerations (if we want to notify on changes)
- Storage integration (if accessing storage metadata)
- Auth integration (Supabase Auth JWT structure)

**PostgreSQL Version Support**
- Minimum PG version (12? 14? 15?)
- Feature detection for newer PG features (JSON_TABLE in PG17)
- Extension dependencies (pgcrypto, uuid-ossp)

**Data Type Handling**
- Custom types (enums, composites)
- Array types in filters
- Range types (tsrange, daterange)
- PostGIS geometry types
- Network types (inet, cidr)


### 8.6 Multi-Tenancy Patterns

**Tenant Isolation Patterns**
- Schema-per-tenant (metadata filtered by schema)
- Row-level tenant_id (permission filter injection)
- Database-per-tenant (connection routing)

**Tenant-Specific Configuration**
- Different rate limits per tenant
- Tenant-specific caching TTLs
- Custom permission rules per tenant

**Cross-Tenant Queries**
- Admin queries across tenants
- Aggregate reporting across tenants


### 8.7 Testing Strategy

**Property-Based Testing**
- Fuzzing the filter parser with random inputs
- SQL injection attempt generation
- Permission evaluation edge cases

**Integration Test Fixtures**
- Standardized test database with complex relationships
- Permission scenario matrices
- Performance regression test suite

**Chaos Testing**
- Metadata table unavailable mid-request
- Connection pool exhaustion
- Malformed JWT handling


### 8.8 Future Extensibility

**Plugin Architecture**
- Custom operators (domain-specific filters)
- Custom authentication providers
- Response transformers (field masking, computed fields)

**GraphQL Layer**
- Could the same metadata power a GraphQL API?
- Subscription support via PostgreSQL NOTIFY

**Event Sourcing**
- Change data capture integration
- Outbox pattern for reliable events
- Webhook triggers on mutations

**Computed Columns**
- Virtual columns defined in metadata
- SQL expression columns
- Relationship aggregates (count of children)


### 8.9 Documentation Needs

**Architecture Decision Records (ADRs)**
- Why Ecto schemas required vs. database introspection
- Why PostgREST operators as default with Hasura compatibility
- Why scope/2 callback as primary authorization
- Why optional JSON permissions layer

**Runbooks**
- Cache invalidation not working (when caching enabled)
- Permission denied debugging
- Performance troubleshooting

**Security Disclosure Process**
- How to report vulnerabilities
- Security patch release process


### 8.10 Migration Tooling

**From PostgREST**
- Script to analyze PostgreSQL GRANTs and generate ExRest resource modules
- Database introspection to auto-generate Ecto schema modules
- Generates `scope/2` callbacks from RLS policies

**From Hasura**
- Direct import of `hdb_metadata` permissions to `ex_rest.permissions` table
- Permission filter syntax is compatible (both operator styles supported)

**From Custom APIs**
- Endpoint mapping analysis tools
- Traffic replay for compatibility testing


### 8.11 Open Questions

1. **Minimum PostgreSQL version?** PG 12 for broad compatibility, or PG 14+ for better JSON performance?

2. **Standalone mode?** Should ExRest be deployable as a standalone service (like PostgREST) in addition to embedded in Phoenix?

3. **Real-time subscriptions?** Is there demand for WebSocket/SSE support for live query results?

4. **License?** MIT for maximum adoption, or AGPL like some competitors?

5. **Name?** Is "ExRest" the final name, or should we consider alternatives (PostgRESTex, PgRest, RestEx)?

6. **Hasura compatibility depth?** Full metadata import, or just permission syntax?


*This document is a living specification. Sections will be updated as implementation progresses and decisions are made.*

---


---

## Part 9: Extensibility & Distributed Deployment

### 9.1 Plugin Architecture

ExRest supports plugins for PostgreSQL extensions (PostGIS, pg_trgm, pgvector, etc.) via a behavior-based system.

#### Plugin Behavior

```elixir
defmodule ExRest.Plugin do
  @moduledoc """
  Behavior for ExRest plugins that add custom operators, types, and filters.
  """

  @type operator_spec :: %{
    name: String.t(),           # Operator name (e.g., "st_within", "@@")
    hasura_syntax: String.t(),  # Hasura-style (e.g., "_st_within")
    postgrest_syntax: String.t(), # PostgREST-style (e.g., "st_within.")
    sql_template: String.t(),   # SQL template with $column, $value placeholders
    arity: 1 | 2,               # Unary or binary operator
    value_type: atom()          # Expected value type (:geometry, :tsquery, etc.)
  }

  @type type_spec :: %{
    name: atom(),
    pg_type: String.t(),
    encoder: (term() -> String.t()),
    decoder: (String.t() -> term())
  }

  @callback name() :: atom()
  @callback version() :: String.t()
  @callback operators() :: [operator_spec()]
  @callback types() :: [type_spec()]
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  
  # Optional callbacks for custom handling
  @callback handle_filter(operator :: String.t(), column :: String.t(), value :: term(), context :: map()) ::
    {:ok, {sql :: String.t(), params :: list()}} | :skip | {:error, term()}
  @callback handle_select(column :: String.t(), context :: map()) ::
    {:ok, sql :: String.t()} | :skip
  
  @optional_callbacks [handle_filter: 4, handle_select: 2]
end
```

#### PostGIS Plugin Example

```elixir
defmodule ExRest.Plugins.PostGIS do
  @behaviour ExRest.Plugin

  @impl true
  def name, do: :postgis

  @impl true
  def version, do: "1.0.0"

  @impl true
  def operators do
    [
      # Spatial relationship operators
      %{
        name: "st_contains",
        hasura_syntax: "_st_contains",
        postgrest_syntax: "st_contains.",
        sql_template: "ST_Contains($column, $value::geometry)",
        arity: 2,
        value_type: :geometry
      },
      %{
        name: "st_within",
        hasura_syntax: "_st_within",
        postgrest_syntax: "st_within.",
        sql_template: "ST_Within($column, $value::geometry)",
        arity: 2,
        value_type: :geometry
      },
      %{
        name: "st_intersects",
        hasura_syntax: "_st_intersects",
        postgrest_syntax: "st_intersects.",
        sql_template: "ST_Intersects($column, $value::geometry)",
        arity: 2,
        value_type: :geometry
      },
      %{
        name: "st_dwithin",
        hasura_syntax: "_st_d_within",
        postgrest_syntax: "st_dwithin.",
        sql_template: "ST_DWithin($column, $value.geometry::geometry, $value.distance)",
        arity: 2,
        value_type: :geometry_with_distance
      },
      # Bounding box operators
      %{
        name: "bbox_intersects",
        hasura_syntax: "_st_intersects_bbox",
        postgrest_syntax: "bbox.",
        sql_template: "$column && $value::geometry",
        arity: 2,
        value_type: :geometry
      }
    ]
  end

  @impl true
  def types do
    [
      %{
        name: :geometry,
        pg_type: "geometry",
        encoder: &encode_geometry/1,
        decoder: &decode_geometry/1
      },
      %{
        name: :geography,
        pg_type: "geography",
        encoder: &encode_geometry/1,
        decoder: &decode_geometry/1
      }
    ]
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_filter("st_dwithin", column, value, _context) when is_map(value) do
    # Special handling for distance-based queries
    # Value format: {"geometry": "POINT(...)", "distance": 1000}
    sql = "ST_DWithin(#{column}, $1::geometry, $2)"
    params = [value["geometry"], value["distance"]]
    {:ok, {sql, params}}
  end
  def handle_filter(_, _, _, _), do: :skip

  # GeoJSON encoding
  defp encode_geometry(%{"type" => _, "coordinates" => _} = geojson) do
    "ST_GeomFromGeoJSON('#{Jason.encode!(geojson)}')"
  end
  defp encode_geometry(wkt) when is_binary(wkt), do: "ST_GeomFromText('#{wkt}')"

  defp decode_geometry(hex) when is_binary(hex) do
    # Returns GeoJSON from PostGIS hex format
    %{raw: hex}
  end
end
```

#### Full-Text Search Plugin (pg_trgm + tsvector)

```elixir
defmodule ExRest.Plugins.FullTextSearch do
  @behaviour ExRest.Plugin

  @impl true
  def name, do: :full_text_search

  @impl true
  def version, do: "1.0.0"

  @impl true
  def operators do
    [
      # tsvector operators
      %{
        name: "fts",
        hasura_syntax: "_fts",
        postgrest_syntax: "fts.",
        sql_template: "$column @@ plainto_tsquery($value)",
        arity: 2,
        value_type: :string
      },
      %{
        name: "plfts",
        hasura_syntax: "_plfts",
        postgrest_syntax: "plfts.",
        sql_template: "$column @@ plainto_tsquery($config, $value)",
        arity: 2,
        value_type: :string_with_config
      },
      %{
        name: "phfts",
        hasura_syntax: "_phfts",
        postgrest_syntax: "phfts.",
        sql_template: "$column @@ phraseto_tsquery($config, $value)",
        arity: 2,
        value_type: :string_with_config
      },
      %{
        name: "wfts",
        hasura_syntax: "_wfts",
        postgrest_syntax: "wfts.",
        sql_template: "$column @@ websearch_to_tsquery($config, $value)",
        arity: 2,
        value_type: :string_with_config
      },
      # pg_trgm operators
      %{
        name: "trgm_similar",
        hasura_syntax: "_similar",
        postgrest_syntax: "trgm.",
        sql_template: "$column % $value",
        arity: 2,
        value_type: :string
      },
      %{
        name: "trgm_word_similar",
        hasura_syntax: "_word_similar",
        postgrest_syntax: "trgm_word.",
        sql_template: "$column %> $value",
        arity: 2,
        value_type: :string
      }
    ]
  end

  @impl true
  def types, do: []

  @impl true
  def init(_opts), do: {:ok, %{}}
end
```

#### pgvector Plugin (AI/ML embeddings)

```elixir
defmodule ExRest.Plugins.PgVector do
  @behaviour ExRest.Plugin

  @impl true
  def name, do: :pgvector

  @impl true
  def version, do: "1.0.0"

  @impl true
  def operators do
    [
      %{
        name: "vec_l2_distance",
        hasura_syntax: "_vec_l2",
        postgrest_syntax: "vec_l2.",
        sql_template: "$column <-> $value::vector",
        arity: 2,
        value_type: :vector
      },
      %{
        name: "vec_cosine_distance",
        hasura_syntax: "_vec_cosine",
        postgrest_syntax: "vec_cos.",
        sql_template: "$column <=> $value::vector",
        arity: 2,
        value_type: :vector
      },
      %{
        name: "vec_inner_product",
        hasura_syntax: "_vec_ip",
        postgrest_syntax: "vec_ip.",
        sql_template: "$column <#> $value::vector",
        arity: 2,
        value_type: :vector
      }
    ]
  end

  @impl true
  def types do
    [
      %{
        name: :vector,
        pg_type: "vector",
        encoder: fn list when is_list(list) -> "[#{Enum.join(list, ",")}]" end,
        decoder: fn str -> String.trim(str, "[]") |> String.split(",") |> Enum.map(&String.to_float/1) end
      }
    ]
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  # Custom handling for KNN queries with ORDER BY
  @impl true
  def handle_filter(op, column, value, context) when op in ["vec_l2_distance", "vec_cosine_distance"] do
    # For vector similarity, often used with ORDER BY and LIMIT rather than WHERE
    if context[:order_by_distance] do
      :skip  # Let the order clause handle it
    else
      # Generate a threshold-based filter
      sql = case op do
        "vec_l2_distance" -> "#{column} <-> $1::vector < $2"
        "vec_cosine_distance" -> "#{column} <=> $1::vector < $2"
      end
      {:ok, {sql, [value["vector"], value["threshold"] || 0.5]}}
    end
  end
  def handle_filter(_, _, _, _), do: :skip
end
```

#### Plugin Registration & Management

```elixir
defmodule ExRest.PluginRegistry do
  use GenServer

  defstruct plugins: %{}, operators: %{}, types: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    plugins = Keyword.get(opts, :plugins, [])
    state = Enum.reduce(plugins, %__MODULE__{}, &register_plugin/2)
    {:ok, state}
  end

  def register(plugin_module, opts \\ []) do
    GenServer.call(__MODULE__, {:register, plugin_module, opts})
  end

  def get_operator(name) do
    GenServer.call(__MODULE__, {:get_operator, name})
  end

  def list_operators do
    GenServer.call(__MODULE__, :list_operators)
  end

  # GenServer callbacks
  def handle_call({:register, module, opts}, _from, state) do
    case module.init(opts) do
      {:ok, _plugin_state} ->
        new_state = register_plugin({module, opts}, state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_operator, name}, _from, state) do
    result = Map.get(state.operators, name) || 
             Map.get(state.operators, "_#{name}") ||  # Try Hasura style
             Map.get(state.operators, "#{name}.")     # Try PostgREST style
    {:reply, result, state}
  end

  def handle_call(:list_operators, _from, state) do
    {:reply, state.operators, state}
  end

  defp register_plugin({module, _opts}, state) do
    # Index operators by all syntax variants
    operators = module.operators()
    |> Enum.reduce(state.operators, fn op, acc ->
      acc
      |> Map.put(op.name, {module, op})
      |> Map.put(op.hasura_syntax, {module, op})
      |> Map.put(op.postgrest_syntax, {module, op})
    end)

    types = module.types()
    |> Enum.reduce(state.types, fn type, acc ->
      Map.put(acc, type.name, {module, type})
    end)

    %{state | 
      plugins: Map.put(state.plugins, module.name(), module),
      operators: operators,
      types: types
    }
  end
end
```

---

### 9.2 Operator Reference (PostgREST vs Hasura vs PostgreSQL)

ExRest uses **PostgREST-style operators by default** (`eq.`, `gt.`, etc.). Hasura-style underscore operators (`_eq`, `_gt`) are supported for backwards compatibility. Both map to the same PostgreSQL operations.

> **Note:** Tables below show PostgREST style first (recommended), then Hasura style (compatible).

#### Core Comparison Operators

| PostgREST | Hasura | PostgreSQL | Description |
|-----------|--------|------------|-------------|
| `eq.` | `_eq` | `=` | Equal |
| `neq.` | `_neq` | `<>` | Not equal |
| `gt.` | `_gt` | `>` | Greater than |
| `gte.` | `_gte` | `>=` | Greater than or equal |
| `lt.` | `_lt` | `<` | Less than |
| `lte.` | `_lte` | `<=` | Less than or equal |

#### String Operators

| PostgREST | Hasura | PostgreSQL | Description |
|-----------|--------|------------|-------------|
| `like.` | `_like` | `LIKE` | Pattern match (case-sensitive) |
| `ilike.` | `_ilike` | `ILIKE` | Pattern match (case-insensitive) |
| `not.like.` | `_nlike` | `NOT LIKE` | Negated pattern match |
| `not.ilike.` | `_nilike` | `NOT ILIKE` | Negated case-insensitive match |
| `match.` | `_similar` | `SIMILAR TO` | SQL regex match |
| `not.match.` | `_nsimilar` | `NOT SIMILAR TO` | Negated SQL regex |
| `~` | `_regex` | `~` | POSIX regex (case-sensitive) |
| `~*` | `_iregex` | `~*` | POSIX regex (case-insensitive) |
| `!~` | `_nregex` | `!~` | Negated POSIX regex |
| `!~*` | `_niregex` | `!~*` | Negated case-insensitive regex |

#### Null Operators

| PostgREST | Hasura | PostgreSQL | Description |
|-----------|--------|------------|-------------|
| `is.null` | `_is_null: true` | `IS NULL` | Is null |
| `is.not.null` | `_is_null: false` | `IS NOT NULL` | Is not null |

#### Array/List Operators

| PostgREST | Hasura | PostgreSQL | Description |
|-----------|--------|------------|-------------|
| `in.` | `_in` | `= ANY(...)` | Value in list |
| `not.in.` | `_nin` | `<> ALL(...)` | Value not in list |
| `cs.` | `_contains` | `@>` | Array contains |
| `_contained_in` | `cd.` | `<@` | Array contained in |
| `_has_key` | `?` | `?` | JSON has key |
| `_has_keys_any` | `?|` | `?|` | JSON has any keys |
| `_has_keys_all` | `?&` | `?&` | JSON has all keys |

#### Range Operators

| Hasura | PostgREST | PostgreSQL | Description |
|--------|-----------|------------|-------------|
| `_adjacent` | `adj.` | `-|-` | Ranges are adjacent |
| `_overlaps` | `ov.` | `&&` | Ranges overlap |
| `_strictly_left` | `sl.` | `<<` | Strictly left of |
| `_strictly_right` | `sr.` | `>>` | Strictly right of |
| `_not_left` | `nxl.` | `&>` | Not extending left |
| `_not_right` | `nxr.` | `<&` | Not extending right |

#### Full-Text Search Operators (via Plugin)

| Hasura | PostgREST | PostgreSQL | Description |
|--------|-----------|------------|-------------|
| `_fts` | `fts.` | `@@ plainto_tsquery()` | Full-text search (plain) |
| `_plfts` | `plfts.` | `@@ plainto_tsquery(config, ...)` | FTS with config |
| `_phfts` | `phfts.` | `@@ phraseto_tsquery()` | Phrase search |
| `_wfts` | `wfts.` | `@@ websearch_to_tsquery()` | Web-style search |

#### PostGIS Operators (via Plugin)

| Hasura | PostgREST | PostgreSQL | Description |
|--------|-----------|------------|-------------|
| `_st_contains` | `st_contains.` | `ST_Contains()` | Geometry A contains B |
| `_st_within` | `st_within.` | `ST_Within()` | Geometry A within B |
| `_st_intersects` | `st_intersects.` | `ST_Intersects()` | Geometries intersect |
| `_st_d_within` | `st_dwithin.` | `ST_DWithin()` | Within distance |
| `_st_intersects_bbox` | `bbox.` | `&&` | Bounding box intersects |

#### pgvector Operators (via Plugin)

| Hasura | PostgREST | PostgreSQL | Description |
|--------|-----------|------------|-------------|
| `_vec_l2` | `vec_l2.` | `<->` | L2 (Euclidean) distance |
| `_vec_cosine` | `vec_cos.` | `<=>` | Cosine distance |
| `_vec_ip` | `vec_ip.` | `<#>` | Inner product |

#### Operator Resolution

```elixir
defmodule ExRest.Operators do
  @core_operators %{
    # Hasura syntax -> {PostgREST syntax, SQL}
    "_eq" => {"eq.", "="},
    "_neq" => {"neq.", "<>"},
    "_gt" => {"gt.", ">"},
    "_gte" => {"gte.", ">="},
    "_lt" => {"lt.", "<"},
    "_lte" => {"lte.", "<="},
    "_like" => {"like.", "LIKE"},
    "_ilike" => {"ilike.", "ILIKE"},
    "_in" => {"in.", "= ANY"},
    "_nin" => {"not.in.", "<> ALL"},
    "_is_null" => {"is.null", "IS NULL"},
    "_contains" => {"cs.", "@>"},
    "_contained_in" => {"cd.", "<@"},
    # ... etc
  }

  @doc """
  Resolve operator from either Hasura or PostgREST syntax to SQL.
  Returns {:ok, {sql_operator, negated?}} or {:error, :unknown_operator}
  """
  def resolve(op) when is_binary(op) do
    # Normalize: strip leading underscore or trailing dot
    normalized = op
      |> String.trim_leading("_")
      |> String.trim_trailing(".")
      |> String.downcase()

    cond do
      # Check core operators
      spec = Map.get(@core_operators, "_#{normalized}") ->
        {_, sql} = spec
        {:ok, {sql, false}}

      # Check negation prefix
      String.starts_with?(normalized, "not.") || String.starts_with?(normalized, "n") ->
        resolve_negated(normalized)

      # Check plugin operators
      {_module, op_spec} = ExRest.PluginRegistry.get_operator(op) ->
        {:ok, {op_spec.sql_template, false}}

      true ->
        {:error, :unknown_operator}
    end
  end

  defp resolve_negated("not." <> rest) do
    case resolve(rest) do
      {:ok, {sql, _}} -> {:ok, {sql, true}}
      error -> error
    end
  end
  defp resolve_negated("n" <> rest) when rest in ["eq", "like", "ilike", "in"] do
    resolve("not.#{rest}")
  end
end
```

---

### 9.3 Custom Query Parameters

Custom URL parameters are handled via the `handle_param/4` callback on your resource module (see Part 2.2). This section covers advanced patterns.

#### Reserved Parameters (Cannot Override)

```elixir
@reserved_params ~w(select order limit offset on_conflict columns count)
```

#### Basic handle_param/4 Pattern

```elixir
defmodule MyApp.API.Properties do
  use ExRest.Resource
  import Ecto.Query
  
  schema "properties" do
    field :address, :string
    field :price, :decimal
    field :location, Geo.PostGIS.Geometry
  end
  
  # ?search=downtown+condo
  def handle_param("search", value, query, _ctx) do
    search = "%#{value}%"
    where(query, [p], ilike(p.address, ^search))
  end
  
  # ?min_price=100000&max_price=500000
  def handle_param("min_price", value, query, _ctx) do
    {price, _} = Integer.parse(value)
    where(query, [p], p.price >= ^price)
  end
  
  def handle_param("max_price", value, query, _ctx) do
    {price, _} = Integer.parse(value)
    where(query, [p], p.price <= ^price)
  end
  
  # ?within_miles=34.0522,-118.2437,10
  def handle_param("within_miles", value, query, _ctx) do
    [lat, lng, miles] = String.split(value, ",")
    {lat_f, _} = Float.parse(lat)
    {lng_f, _} = Float.parse(lng)
    {miles_f, _} = Float.parse(miles)
    meters = miles_f * 1609.34
    
    point = %Geo.Point{coordinates: {lng_f, lat_f}, srid: 4326}
    where(query, [p], fragment("ST_DWithin(?::geography, ?::geography, ?)", p.location, ^point, ^meters))
  end
  
  # Fallthrough - ignore unknown params
  def handle_param(_key, _value, query, _ctx), do: query
end
```

#### Full-Text Search Pattern

```elixir
defmodule MyApp.API.Articles do
  use ExRest.Resource
  import Ecto.Query
  
  schema "articles" do
    field :title, :string
    field :body, :string
    field :search_vector, ExRest.Types.TSVector  # Generated column
  end
  
  # ?q=elixir+phoenix+tutorial
  def handle_param("q", value, query, _ctx) do
    query
    |> where([a], fragment("? @@ websearch_to_tsquery('english', ?)", a.search_vector, ^value))
    |> order_by([a], desc: fragment("ts_rank(?, websearch_to_tsquery('english', ?))", a.search_vector, ^value))
  end
  
  def handle_param(_, _, query, _), do: query
end
```

#### Computed/Aggregate Filters

```elixir
defmodule MyApp.API.Authors do
  use ExRest.Resource
  import Ecto.Query
  
  schema "authors" do
    field :name, :string
    has_many :books, MyApp.Book
  end
  
  # ?min_books=5 - authors with at least 5 books
  def handle_param("min_books", value, query, _ctx) do
    {count, _} = Integer.parse(value)
    
    from a in query,
      join: b in assoc(a, :books),
      group_by: a.id,
      having: count(b.id) >= ^count
  end
  
  # ?has_bestseller=true
  def handle_param("has_bestseller", "true", query, _ctx) do
    from a in query,
      join: b in assoc(a, :books),
      where: b.bestseller == true,
      distinct: true
  end
  
  def handle_param(_, _, query, _), do: query
end
```

#### Context-Aware Filters

```elixir
defmodule MyApp.API.Documents do
  use ExRest.Resource
  import Ecto.Query
  
  schema "documents" do
    field :title, :string
    field :classification, :string
    field :department_id, :integer
  end
  
  # ?my_department=true - filter to user's department
  def handle_param("my_department", "true", query, context) do
    where(query, [d], d.department_id == ^context.assigns.department_id)
  end
  
  # ?accessible=true - complex permission check
  def handle_param("accessible", "true", query, context) do
    case context.role do
      "admin" -> query
      "manager" -> 
        where(query, [d], d.department_id in ^context.assigns.managed_departments)
      _ -> 
        where(query, [d], d.classification == "public")
    end
  end
  
  def handle_param(_, _, query, _), do: query
end
```

---


### 9.4 Optional JSON Permissions

JSON permissions provide runtime-configurable, role-based access control as an optional layer on top of `scope/2`. ExRest uses **PostgREST-style operators by default** (`eq.`, `gt.`, etc.) but supports Hasura-style underscore operators (`_eq`, `_gt`) for backwards compatibility.

> **Hasura Metadata Compatibility:** ExRest permission filters are designed to be compatible with Hasura's `hdb_metadata` permission format. If migrating from Hasura, you can import existing permission definitions directly. Both operator styles are fully supported and interchangeable.

**When to use JSON Permissions:**
- Role-based filters need to change without deployment
- Non-developers need to configure access rules
- Multi-tenant systems with tenant-specific permissions
- Migrating from Hasura and want to reuse existing permissions

**When scope/2 is sufficient:**
- Permissions are stable and code-based
- Complex authorization logic requiring Elixir
- Tenant isolation that applies to all roles
- Soft deletes, audit trails

#### Permission Table Schema

```sql
CREATE TABLE ex_rest.permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  resource TEXT NOT NULL,     -- Module name or table name
  role TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('select', 'insert', 'update', 'delete')),
  
  -- Filter expression (PostgREST or Hasura operator syntax)
  filter JSONB,               -- Row filter as JSON boolean expression
  columns TEXT[],             -- Allowed columns (null = all from schema)
  check_expr JSONB,           -- Validation for insert/update
  presets JSONB,              -- Column presets (auto-set values)
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(resource, role, action)
);

-- Notify on changes for cache invalidation
CREATE OR REPLACE FUNCTION ex_rest.notify_permission_change()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify('ex_rest_permissions_changed', 
    json_build_object('resource', COALESCE(NEW.resource, OLD.resource))::text);
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER permissions_changed
AFTER INSERT OR UPDATE OR DELETE ON ex_rest.permissions
FOR EACH ROW EXECUTE FUNCTION ex_rest.notify_permission_change();
```

#### Example Permissions (PostgREST Style - Recommended)

```sql
-- Users can only see their own orders
INSERT INTO ex_rest.permissions (resource, role, action, filter, columns) VALUES
('orders', 'user', 'select', 
  '{"user_id": {"eq.": "X-ExRest-User-Id"}}',
  ARRAY['id', 'reference', 'status', 'total', 'inserted_at']);

-- Users can create orders (reference only, other fields preset)
INSERT INTO ex_rest.permissions (resource, role, action, columns, presets) VALUES
('orders', 'user', 'insert',
  ARRAY['reference', 'shipping_address_id'],
  '{"user_id": "X-ExRest-User-Id", "status": "pending"}');

-- Users can update only pending orders they own
INSERT INTO ex_rest.permissions (resource, role, action, filter, columns) VALUES
('orders', 'user', 'update',
  '{"and": [{"user_id": {"eq.": "X-ExRest-User-Id"}}, {"status": {"eq.": "pending"}}]}',
  ARRAY['shipping_address_id']);

-- Admins have full access
INSERT INTO ex_rest.permissions (resource, role, action, filter, columns) VALUES
('orders', 'admin', 'select', NULL, NULL),
('orders', 'admin', 'insert', NULL, NULL),
('orders', 'admin', 'update', NULL, NULL),
('orders', 'admin', 'delete', NULL, NULL);
```

#### JSON Filter Syntax

PostgREST-style operators (recommended):

```json
// Simple equality
{"status": {"eq.": "active"}}

// Comparison operators
{"total": {"gt.": 100}}
{"total": {"gte.": 100}}
{"total": {"lt.": 1000}}
{"total": {"lte.": 1000}}
{"status": {"neq.": "cancelled"}}

// String operators
{"name": {"like.": "%smith%"}}
{"email": {"ilike.": "%@example.com"}}

// List operators
{"status": {"in.": ["pending", "confirmed"]}}

// Null checks
{"deleted_at": {"is.": null}}

// Logical operators
{"and": [{"status": {"eq.": "active"}}, {"total": {"gt.": 0}}]}
{"or": [{"role": {"eq.": "admin"}}, {"is_owner": {"eq.": true}}]}
{"not": {"status": {"eq.": "cancelled"}}}

// Session variable substitution
{"user_id": {"eq.": "X-ExRest-User-Id"}}
{"tenant_id": {"eq.": "X-ExRest-Tenant-Id"}}
```

Hasura-style operators (backwards compatible):

```json
// All Hasura underscore operators work identically
{"status": {"_eq": "active"}}
{"_and": [{"status": {"_eq": "active"}}, {"total": {"_gt": 100}}]}
{"user_id": {"_eq": "X-Hasura-User-Id"}}
```

Both styles can be mixed in the same filter expression.

#### Configuration

```elixir
# config/config.exs
config :ex_rest, :permissions,
  enabled: true,  # false to rely only on scope/2
  table: "ex_rest.permissions",
  cache_ttl: :timer.minutes(5),
  default_deny: true  # No permission = no access (for that role)
```

#### Pipeline Integration

JSON permissions are applied after `scope/2` but before URL filters:

```
scope/2          → Always runs (tenant isolation, soft deletes)
    ↓
JSON permissions → Optional, per-role row filters
    ↓
URL filters      → Client-specified filters (?status=eq.active)
```

#### Permission Cache

```elixir
defmodule ExRest.PermissionsCache do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(opts) do
    # Subscribe to NOTIFY
    {:ok, conn} = Postgrex.Notifications.start_link(opts[:database])
    Postgrex.Notifications.listen(conn, "ex_rest_permissions_changed")
    
    # Initial load
    permissions = load_all_permissions(opts)
    
    {:ok, %{permissions: permissions, conn: conn}}
  end
  
  def get({resource, role, action}) do
    GenServer.call(__MODULE__, {:get, resource, role, action})
  end
  
  def handle_call({:get, resource, role, action}, _from, state) do
    result = get_in(state.permissions, [resource, role, action])
    {:reply, result, state}
  end
  
  def handle_info({:notification, _, _, "ex_rest_permissions_changed", payload}, state) do
    # Reload permissions for changed resource
    %{"resource" => resource} = Jason.decode!(payload)
    permissions = reload_resource_permissions(resource, state.permissions)
    {:noreply, %{state | permissions: permissions}}
  end
end
```

---
### 9.5 Distributed Caching with Nebulex (Optional)

ExRest provides **optional** caching integration using Nebulex. Caching is disabled by default and must be explicitly enabled.

> **When to enable caching:** High-read, low-write workloads with stable data. Not recommended for frequently changing data or when cache invalidation complexity outweighs benefits.

#### Why Nebulex over Cachex

| Feature | Cachex | Nebulex |
|---------|--------|---------|
| Local caching | ✅ | ✅ |
| Distributed (multi-node) | ❌ | ✅ |
| External backends (Redis) | ❌ | ✅ |
| Multi-level (L1 + L2) | ❌ | ✅ |
| Adapter pattern | ❌ | ✅ |
| Telemetry integration | ✅ | ✅ |
| TTL support | ✅ | ✅ |

#### Enabling Caching

```elixir
# config/config.exs
config :ex_rest, :cache,
  enabled: true,  # Default: false
  adapter: ExRest.Cache,
  default_ttl: :timer.minutes(5),
  stats: true

# To disable (default):
config :ex_rest, :cache, enabled: false
```

#### Local-Only Cache (Development/Single Node)

```elixir
defmodule ExRest.Cache do
  use Nebulex.Cache,
    otp_app: :ex_rest,
    adapter: Nebulex.Adapters.Local,
    gc_interval: :timer.hours(1)
end

# config/config.exs
config :ex_rest, ExRest.Cache,
  gc_interval: :timer.hours(1),
  max_size: 100_000,
  allocated_memory: 100_000_000,  # 100MB
  gc_cleanup_min_timeout: :timer.seconds(10),
  gc_cleanup_max_timeout: :timer.minutes(10)
```

#### Distributed Cache (Multi-Node with Partitioned Strategy)

```elixir
defmodule ExRest.Cache do
  use Nebulex.Cache,
    otp_app: :ex_rest,
    adapter: Nebulex.Adapters.Partitioned,
    primary_storage_adapter: Nebulex.Adapters.Local
end

# config/config.exs  
config :ex_rest, ExRest.Cache,
  primary: [
    gc_interval: :timer.hours(1),
    max_size: 50_000
  ]
```

#### Multi-Level Cache (L1 Local + L2 Redis)

```elixir
defmodule ExRest.Cache.L1 do
  use Nebulex.Cache,
    otp_app: :ex_rest,
    adapter: Nebulex.Adapters.Local
end

defmodule ExRest.Cache.L2 do
  use Nebulex.Cache,
    otp_app: :ex_rest,
    adapter: NebulexRedisAdapter
end

defmodule ExRest.Cache do
  use Nebulex.Cache,
    otp_app: :ex_rest,
    adapter: Nebulex.Adapters.Multilevel

  defmodule L1 do
    use Nebulex.Cache,
      otp_app: :ex_rest,
      adapter: Nebulex.Adapters.Local
  end

  defmodule L2 do
    use Nebulex.Cache,
      otp_app: :ex_rest,
      adapter: NebulexRedisAdapter
  end
end

# config/config.exs
config :ex_rest, ExRest.Cache,
  model: :inclusive,  # L1 includes L2 data
  levels: [
    {ExRest.Cache.L1, gc_interval: :timer.minutes(5), max_size: 10_000},
    {ExRest.Cache.L2, 
      conn_opts: [host: "redis.example.com", port: 6379],
      default_ttl: :timer.hours(1)
    }
  ]
```

#### Pluggable Cache Adapter

```elixir
defmodule ExRest.CacheAdapter do
  @moduledoc """
  Behavior for cache adapters. Users can implement custom caching.
  """

  @callback get(key :: term(), opts :: keyword()) :: {:ok, term()} | {:error, :not_found}
  @callback put(key :: term(), value :: term(), opts :: keyword()) :: :ok | {:error, term()}
  @callback delete(key :: term(), opts :: keyword()) :: :ok
  @callback delete_pattern(pattern :: String.t(), opts :: keyword()) :: :ok
  @callback stats() :: map()
end

defmodule ExRest.CacheAdapter.Nebulex do
  @behaviour ExRest.CacheAdapter
  
  @impl true
  def get(key, opts) do
    cache = Keyword.get(opts, :cache, ExRest.Cache)
    case cache.get(key) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  def put(key, value, opts) do
    cache = Keyword.get(opts, :cache, ExRest.Cache)
    ttl = Keyword.get(opts, :ttl, :timer.minutes(5))
    cache.put(key, value, ttl: ttl)
    :ok
  end

  @impl true
  def delete(key, opts) do
    cache = Keyword.get(opts, :cache, ExRest.Cache)
    cache.delete(key)
    :ok
  end

  @impl true
  def delete_pattern(pattern, opts) do
    # For distributed invalidation
    cache = Keyword.get(opts, :cache, ExRest.Cache)
    
    # Nebulex doesn't support pattern delete natively
    # Use stream + delete for local, or Redis SCAN for L2
    cache.stream()
    |> Stream.filter(fn {key, _} -> matches_pattern?(key, pattern) end)
    |> Stream.each(fn {key, _} -> cache.delete(key) end)
    |> Stream.run()
    
    :ok
  end
end

# Allow user to provide custom adapter
config :ex_rest, :cache_adapter, MyApp.CustomCacheAdapter
```

#### Cache Key Strategy

```elixir
defmodule ExRest.Cache.KeyBuilder do
  @moduledoc """
  Build cache keys that work correctly in distributed environments.
  """

  def build(request, context) do
    # Components that affect the query result
    components = [
      request.table,
      request.method,
      normalize_query(request.query_params),
      context.role,
      context.user_id,
      context.tenant_id
    ]
    |> Enum.reject(&is_nil/1)

    # Use SHA256 for consistent hashing across nodes
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(components))
           |> Base.encode16(case: :lower)
           |> binary_part(0, 16)

    # Prefix for pattern-based invalidation
    "exrest:#{request.table}:#{hash}"
  end

  def invalidation_pattern(table) do
    "exrest:#{table}:*"
  end
end
```

---

### 9.6 Multi-Node OTP Deployment

ExRest is designed for distributed OTP deployments with proper cluster coordination.

#### Cluster Formation with libcluster

```elixir
# config/runtime.exs
config :libcluster,
  topologies: [
    exrest: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "exrest-headless",
        application_name: "exrest"
      ]
    ]
  ]

# For development/docker
config :libcluster,
  topologies: [
    exrest: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"exrest@node1", :"exrest@node2"]]
    ]
  ]
```

#### Application Supervision Tree

```elixir
defmodule ExRest.Application do
  use Application

  def start(_type, _args) do
    # Core children (always started)
    core_children = [
      # Phoenix PubSub for cross-node communication
      {Phoenix.PubSub, name: ExRest.PubSub},

      # Resource registry (discovers Ecto schemas with use ExRest.Resource)
      {ExRest.Registry, [otp_app: Application.get_env(:ex_rest, :otp_app)]},

      # Plugin registry
      {ExRest.PluginRegistry, [
        plugins: Application.get_env(:ex_rest, :plugins, [])
      ]},

      # Telemetry
      ExRest.Telemetry
    ]
    
    # Optional: Cluster formation (for multi-node)
    cluster_children = if Application.get_env(:libcluster, :topologies) do
      [{Cluster.Supervisor, [
        Application.get_env(:libcluster, :topologies),
        [name: ExRest.ClusterSupervisor]
      ]}]
    else
      []
    end

    # Optional: JSON permissions cache (if enabled)
    permissions_children = if Application.get_env(:ex_rest, [:permissions, :enabled], false) do
      [{ExRest.PermissionsCache, [
        pubsub: ExRest.PubSub,
        table: Application.get_env(:ex_rest, [:permissions, :table], "ex_rest.permissions")
      ]}]
    else
      []
    end

    # Optional: Distributed cache (if enabled)
    cache_children = if Application.get_env(:ex_rest, [:cache, :enabled], false) do
      [ExRest.Cache]
    else
      []
    end

    # Optional: Rate limiter (if enabled)
    rate_limiter_children = if Application.get_env(:ex_rest, [:rate_limiter, :enabled], false) do
      [{ExRest.RateLimiter, Application.get_env(:ex_rest, :rate_limiter, [])}]
    else
      []
    end

    children = cluster_children ++ 
               core_children ++ 
               permissions_children ++
               cache_children ++ 
               rate_limiter_children

    opts = [strategy: :one_for_one, name: ExRest.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### Distributed Metadata Synchronization

```elixir
defmodule ExRest.MetadataManager do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    source = Keyword.fetch!(opts, :source)

    # Subscribe to local PubSub for cross-node sync
    Phoenix.PubSub.subscribe(pubsub, "exrest:metadata")

    # Subscribe to PostgreSQL notifications
    {:ok, source_module, source_state} = init_source(source)

    state = %{
      pubsub: pubsub,
      source: {source_module, source_state},
      metadata: %{},
      version: 0
    }

    # Initial load
    {:ok, state, {:continue, :load_metadata}}
  end

  def handle_continue(:load_metadata, state) do
    {source_module, source_state} = state.source
    
    case source_module.load(source_state) do
      {:ok, metadata} ->
        new_version = :erlang.monotonic_time()
        Logger.info("Loaded metadata v#{new_version}: #{map_size(metadata)} tables")
        
        {:noreply, %{state | metadata: metadata, version: new_version}}

      {:error, reason} ->
        Logger.error("Failed to load metadata: #{inspect(reason)}")
        # Retry after delay
        Process.send_after(self(), :retry_load, 5_000)
        {:noreply, state}
    end
  end

  # Handle PostgreSQL NOTIFY
  def handle_info({:notification, _pid, _ref, "ex_rest_metadata_changed", payload}, state) do
    Logger.info("Metadata changed notification: #{payload}")
    
    # Broadcast to all nodes via PubSub
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "exrest:metadata",
      {:metadata_changed, Node.self(), payload}
    )

    {:noreply, state, {:continue, :load_metadata}}
  end

  # Handle cross-node sync
  def handle_info({:metadata_changed, origin_node, _payload}, state) when origin_node != Node.self() do
    Logger.info("Metadata change from #{origin_node}, reloading...")
    {:noreply, state, {:continue, :load_metadata}}
  end
  def handle_info({:metadata_changed, _, _}, state) do
    # Ignore our own broadcasts
    {:noreply, state}
  end

  def handle_info(:retry_load, state) do
    {:noreply, state, {:continue, :load_metadata}}
  end

  # Public API
  def get_metadata(table) do
    GenServer.call(__MODULE__, {:get_metadata, table})
  end

  def handle_call({:get_metadata, table}, _from, state) do
    result = Map.get(state.metadata, table)
    {:reply, result, state}
  end
end
```

#### Distributed Cache Invalidation

```elixir
defmodule ExRest.Cache.Invalidator do
  @moduledoc """
  Handles cache invalidation across nodes.
  """

  def invalidate_table(table) do
    # Invalidate locally
    pattern = ExRest.Cache.KeyBuilder.invalidation_pattern(table)
    ExRest.CacheAdapter.delete_pattern(pattern, cache: ExRest.Cache)

    # Broadcast to other nodes
    Phoenix.PubSub.broadcast(
      ExRest.PubSub,
      "exrest:cache_invalidation",
      {:invalidate, table}
    )
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    Phoenix.PubSub.subscribe(ExRest.PubSub, "exrest:cache_invalidation")
    {:ok, %{}}
  end

  def handle_info({:invalidate, table}, state) do
    # Don't re-broadcast, just invalidate locally
    pattern = ExRest.Cache.KeyBuilder.invalidation_pattern(table)
    ExRest.CacheAdapter.delete_pattern(pattern, cache: ExRest.Cache)
    {:noreply, state}
  end
end
```

#### Health Checks for Kubernetes

```elixir
defmodule ExRest.HealthPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(%{path_info: ["health", "live"]} = conn, _opts) do
    # Liveness: Is the process running?
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
    |> halt()
  end

  def call(%{path_info: ["health", "ready"]} = conn, _opts) do
    # Readiness: Can we serve requests?
    checks = [
      {:database, check_database()},
      {:metadata, check_metadata()},
      {:cache, check_cache()},
      {:cluster, check_cluster()}
    ]

    all_ok = Enum.all?(checks, fn {_, status} -> status == :ok end)

    status = if all_ok, do: 200, else: 503
    body = Jason.encode!(%{
      status: if(all_ok, do: "ready", else: "not_ready"),
      checks: Map.new(checks)
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp check_database do
    case Postgrex.query(ExRest.Repo, "SELECT 1", [], timeout: 1000) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp check_metadata do
    case ExRest.MetadataManager.get_metadata("__health_check__") do
      # Returns nil for non-existent table, but proves service is responding
      _ -> :ok
    end
  rescue
    _ -> :error
  end

  defp check_cache do
    key = "__health_check_#{:rand.uniform(1000)}"
    ExRest.Cache.put(key, "ok", ttl: 1000)
    case ExRest.Cache.get(key) do
      "ok" -> 
        ExRest.Cache.delete(key)
        :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp check_cluster do
    nodes = Node.list()
    expected = Application.get_env(:ex_rest, :expected_cluster_size, 1) - 1
    if length(nodes) >= expected, do: :ok, else: :degraded
  end
end
```

#### Deployment Configuration Summary

```yaml
# kubernetes/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exrest
spec:
  replicas: 3
  selector:
    matchLabels:
      app: exrest
  template:
    spec:
      containers:
      - name: exrest
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: RELEASE_DISTRIBUTION
          value: "name"
        - name: RELEASE_NODE
          value: "exrest@$(POD_IP)"
        livenessProbe:
          httpGet:
            path: /health/live
            port: 4000
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: exrest-headless
spec:
  clusterIP: None  # Headless for DNS-based discovery
  selector:
    app: exrest
  ports:
  - port: 4369      # EPMD
    name: epmd
  - port: 4000      # HTTP
    name: http
```

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :ex_rest,
    metadata_source: {:database, 
      table: System.get_env("METADATA_TABLE", "ex_rest.metadata")
    },
    cache_adapter: ExRest.CacheAdapter.Nebulex,
    expected_cluster_size: String.to_integer(System.get_env("CLUSTER_SIZE", "3"))

  config :ex_rest, ExRest.Cache,
    # Use partitioned cache for multi-node
    adapter: Nebulex.Adapters.Partitioned

  config :libcluster,
    topologies: [
      exrest: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: System.get_env("CLUSTER_SERVICE", "exrest-headless"),
          application_name: "exrest",
          polling_interval: 5_000
        ]
      ]
    ]
end
```


---


---

### 9.7 Pluggable Rate Limiting with Hammer (Optional)

ExRest provides **optional** rate limiting via the Hammer library. Rate limiting is disabled by default and must be explicitly enabled.

> **When to enable rate limiting:** Public APIs, multi-tenant systems, or when protecting against abuse. May not be needed for internal APIs or trusted clients.

#### Enabling Rate Limiting

```elixir
# config/config.exs
config :ex_rest, :rate_limiter,
  enabled: true,  # Default: false
  adapter: ExRest.RateLimiter.Hammer,
  defaults: [
    limit: 100,
    window_ms: 60_000  # 1 minute
  ]

# To disable (default):
config :ex_rest, :rate_limiter, enabled: false

# Hammer backend configuration (only needed if enabled)
config :hammer,
  backend: {Hammer.Backend.ETS, [
    expiry_ms: 60_000 * 60,  # 1 hour
    cleanup_interval_ms: 60_000 * 10  # 10 minutes
  ]}
```

#### Rate Limiter Behavior

```elixir
defmodule ExRest.RateLimiter do
  @moduledoc """
  Behavior for rate limiting adapters.
  """

  @type key :: String.t()
  @type result :: {:allow, count :: integer()} | {:deny, retry_after_ms :: integer()}

  @callback check(key, limit :: integer(), window_ms :: integer()) :: result()
  @callback reset(key) :: :ok
  @callback inspect(key) :: {:ok, map()} | {:error, :not_found}

  @doc """
  Check rate limit using configured adapter.
  """
  def check(key, opts \\ []) do
    adapter = get_adapter()
    limit = Keyword.get(opts, :limit, default_limit())
    window = Keyword.get(opts, :window_ms, default_window())
    
    if enabled?() do
      adapter.check(key, limit, window)
    else
      {:allow, 0}
    end
  end

  def reset(key) do
    if enabled?(), do: get_adapter().reset(key), else: :ok
  end

  defp enabled?, do: Application.get_env(:ex_rest, [:rate_limiter, :enabled], false)
  defp get_adapter, do: Application.get_env(:ex_rest, [:rate_limiter, :adapter], __MODULE__.Hammer)
  defp default_limit, do: get_in(Application.get_env(:ex_rest, :rate_limiter, []), [:defaults, :limit]) || 100
  defp default_window, do: get_in(Application.get_env(:ex_rest, :rate_limiter, []), [:defaults, :window_ms]) || 60_000
end
```

#### Hammer Adapter Implementation

```elixir
defmodule ExRest.RateLimiter.Hammer do
  @behaviour ExRest.RateLimiter

  @impl true
  def check(key, limit, window_ms) do
    case Hammer.check_rate(key, window_ms, limit) do
      {:allow, count} ->
        {:allow, count}
      {:deny, retry_after} ->
        {:deny, retry_after}
    end
  end

  @impl true
  def reset(key) do
    Hammer.delete_buckets(key)
    :ok
  end

  @impl true
  def inspect(key) do
    case Hammer.inspect_bucket(key, 60_000, 100) do
      {count, count_remaining, ms_to_next, created_at, updated_at} ->
        {:ok, %{
          count: count,
          remaining: count_remaining,
          reset_in_ms: ms_to_next,
          created_at: created_at,
          updated_at: updated_at
        }}
      nil ->
        {:error, :not_found}
    end
  end
end
```

#### Distributed Rate Limiting (Multi-Node)

For multi-node deployments, use Hammer's Redis backend:

```elixir
# mix.exs
defp deps do
  [
    {:hammer, "~> 6.1"},
    {:hammer_backend_redis, "~> 6.1"}  # For distributed
  ]
end

# config/runtime.exs
if config_env() == :prod do
  config :hammer,
    backend: {Hammer.Backend.Redis, [
      expiry_ms: 60_000 * 60,
      redix_config: [
        host: System.get_env("REDIS_HOST", "localhost"),
        port: String.to_integer(System.get_env("REDIS_PORT", "6379"))
      ],
      pool_size: 4,
      pool_max_overflow: 2
    ]}
end
```

#### Per-Table and Per-Endpoint Limits

```elixir
# config/config.exs
config :ex_rest, :rate_limiter,
  enabled: true,
  adapter: ExRest.RateLimiter.Hammer,
  defaults: [limit: 100, window_ms: 60_000],
  
  # Override per table
  tables: %{
    "users" => [limit: 50, window_ms: 60_000],
    "orders" => [limit: 200, window_ms: 60_000],
    "reports" => [limit: 10, window_ms: 60_000]  # Expensive queries
  },
  
  # Override per HTTP method
  methods: %{
    "POST" => [limit: 30, window_ms: 60_000],
    "PATCH" => [limit: 30, window_ms: 60_000],
    "DELETE" => [limit: 10, window_ms: 60_000]
  },
  
  # Special endpoints
  endpoints: %{
    "/rpc/generate_report" => [limit: 5, window_ms: 300_000],  # 5 per 5 min
    "/admin/*" => [limit: 1000, window_ms: 60_000]  # Higher for admin
  }
```

#### Rate Limit Key Strategies

```elixir
defmodule ExRest.RateLimiter.KeyBuilder do
  @moduledoc """
  Build rate limit keys based on request context.
  """

  @type strategy :: :user | :ip | :user_and_ip | :api_key | :custom

  def build(conn, request, strategy \\ :user_and_ip) do
    base = case strategy do
      :user ->
        conn.assigns[:user_id] || "anonymous"
      
      :ip ->
        get_client_ip(conn)
      
      :user_and_ip ->
        user = conn.assigns[:user_id] || "anon"
        ip = get_client_ip(conn)
        "#{user}:#{ip}"
      
      :api_key ->
        conn.assigns[:api_key] || get_client_ip(conn)
      
      {:custom, fun} when is_function(fun, 2) ->
        fun.(conn, request)
    end

    # Include table/endpoint for granular limits
    "exrest:rl:#{request.table}:#{request.method}:#{base}"
  end

  defp get_client_ip(conn) do
    # Check X-Forwarded-For, X-Real-IP, then remote_ip
    forwarded = get_req_header(conn, "x-forwarded-for") |> List.first()
    real_ip = get_req_header(conn, "x-real-ip") |> List.first()
    
    cond do
      forwarded -> forwarded |> String.split(",") |> List.first() |> String.trim()
      real_ip -> real_ip
      true -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
```

#### Rate Limiter Plug

```elixir
defmodule ExRest.Plug.RateLimiter do
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    if ExRest.RateLimiter.enabled?() do
      do_check(conn, opts)
    else
      conn
    end
  end

  defp do_check(conn, opts) do
    request = conn.assigns[:exrest_request]
    strategy = Keyword.get(opts, :key_strategy, :user_and_ip)
    key = ExRest.RateLimiter.KeyBuilder.build(conn, request, strategy)
    
    # Get limits for this specific request
    {limit, window} = get_limits(request)

    case ExRest.RateLimiter.check(key, limit: limit, window_ms: window) do
      {:allow, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", to_string(limit - count))
        |> put_resp_header("x-ratelimit-reset", to_string(reset_timestamp(window)))

      {:deny, retry_after} ->
        Logger.warning("Rate limit exceeded for #{key}")
        
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("x-ratelimit-reset", to_string(reset_timestamp(window)))
        |> put_resp_header("retry-after", to_string(div(retry_after, 1000)))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{
          error: "rate_limit_exceeded",
          message: "Too many requests",
          retry_after_seconds: div(retry_after, 1000)
        }))
        |> halt()
    end
  end

  defp get_limits(request) do
    config = Application.get_env(:ex_rest, :rate_limiter, [])
    defaults = Keyword.get(config, :defaults, [])
    
    # Check endpoint overrides first
    endpoint_limits = get_in(config, [:endpoints, request.path])
    
    # Then table overrides
    table_limits = get_in(config, [:tables, request.table])
    
    # Then method overrides
    method_limits = get_in(config, [:methods, request.method])
    
    # Merge with priority: endpoint > table > method > defaults
    merged = defaults
      |> Keyword.merge(method_limits || [])
      |> Keyword.merge(table_limits || [])
      |> Keyword.merge(endpoint_limits || [])

    {Keyword.get(merged, :limit, 100), Keyword.get(merged, :window_ms, 60_000)}
  end

  defp reset_timestamp(window_ms) do
    now = System.system_time(:second)
    now + div(window_ms, 1000)
  end
end
```

#### Disable Rate Limiting (Opt-Out)

```elixir
# Completely disable
config :ex_rest, :rate_limiter, enabled: false

# Or disable per-request via plug option
plug ExRest.Plug.RateLimiter, except: ["/health/*", "/metrics"]

# Or skip programmatically
defmodule MyApp.Router do
  pipeline :api do
    plug ExRest.Plug.RateLimiter, 
      skip_if: fn conn -> conn.assigns[:skip_rate_limit] end
  end
end
```

#### Custom Rate Limiter Adapter

```elixir
defmodule MyApp.RateLimiter.Custom do
  @behaviour ExRest.RateLimiter

  @impl true
  def check(key, limit, window_ms) do
    # Your custom implementation
    # Could use database, external service, etc.
    case MyApp.RateLimitService.check(key, limit, window_ms) do
      :ok -> {:allow, 1}
      {:error, :exceeded, retry_after} -> {:deny, retry_after}
    end
  end

  @impl true
  def reset(key) do
    MyApp.RateLimitService.reset(key)
  end

  @impl true
  def inspect(key) do
    MyApp.RateLimitService.get_bucket(key)
  end
end

# config/config.exs
config :ex_rest, :rate_limiter,
  enabled: true,
  adapter: MyApp.RateLimiter.Custom
```

#### Rate Limiting with Role-Based Limits

```elixir
defmodule ExRest.RateLimiter.RoleBased do
  @moduledoc """
  Rate limiting with different limits per user role.
  """

  @role_limits %{
    "admin" => [limit: 10_000, window_ms: 60_000],
    "premium" => [limit: 1_000, window_ms: 60_000],
    "user" => [limit: 100, window_ms: 60_000],
    "anonymous" => [limit: 20, window_ms: 60_000]
  }

  def get_limits_for_role(role) do
    Map.get(@role_limits, role, @role_limits["anonymous"])
  end
end

# In the plug
defp get_limits(conn, request) do
  role = conn.assigns[:role] || "anonymous"
  role_limits = ExRest.RateLimiter.RoleBased.get_limits_for_role(role)
  
  # Still allow table/endpoint overrides
  # ...merge logic...
end
```

#### Telemetry Integration

```elixir
defmodule ExRest.RateLimiter.Telemetry do
  def attach do
    :telemetry.attach_many(
      "exrest-rate-limiter",
      [
        [:exrest, :rate_limit, :check],
        [:exrest, :rate_limit, :allow],
        [:exrest, :rate_limit, :deny]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:exrest, :rate_limit, :check], measurements, metadata, _config) do
    # Log/metric for every check
  end

  def handle_event([:exrest, :rate_limit, :deny], measurements, metadata, _config) do
    # Alert on rate limit exceeded
    Logger.warning("Rate limit denied",
      key: metadata.key,
      limit: metadata.limit,
      retry_after: measurements.retry_after_ms
    )
  end
end

# Emit telemetry in the adapter
def check(key, limit, window_ms) do
  start = System.monotonic_time()
  result = Hammer.check_rate(key, window_ms, limit)
  duration = System.monotonic_time() - start

  :telemetry.execute(
    [:exrest, :rate_limit, :check],
    %{duration: duration},
    %{key: key, limit: limit, window_ms: window_ms}
  )

  case result do
    {:allow, count} ->
      :telemetry.execute([:exrest, :rate_limit, :allow], %{count: count}, %{key: key})
      {:allow, count}
    {:deny, retry_after} ->
      :telemetry.execute([:exrest, :rate_limit, :deny], %{retry_after_ms: retry_after}, %{key: key, limit: limit})
      {:deny, retry_after}
  end
end
```


---

## Appendix A: Complete Operator Reference

```elixir
# lib/ex_rest/operators.ex
defmodule ExRest.Operators do
  @moduledoc """
  Complete mapping of PostgREST operators to PostgreSQL.
  """

  @operators %{
    # Comparison
    eq: {:binary, "="},
    neq: {:binary, "<>"},
    gt: {:binary, ">"},
    gte: {:binary, ">="},
    lt: {:binary, "<"},
    lte: {:binary, "<="},

    # Pattern matching
    like: {:binary, "LIKE"},
    ilike: {:binary, "ILIKE"},
    match: {:binary, "~"},
    imatch: {:binary, "~*"},

    # Special
    is: {:is, "IS"},
    isdistinct: {:binary, "IS DISTINCT FROM"},
    in: {:list, "IN"},

    # Array
    cs: {:binary, "@>"},
    cd: {:binary, "<@"},
    ov: {:binary, "&&"},

    # Range
    sl: {:binary, "<<"},
    sr: {:binary, ">>"},
    nxl: {:binary, "&<"},
    nxr: {:binary, "&>"},
    adj: {:binary, "-|-"},

    # Full-text search
    fts: {:fts, "to_tsquery"},
    plfts: {:fts, "plainto_tsquery"},
    phfts: {:fts, "phraseto_tsquery"},
    wfts: {:fts, "websearch_to_tsquery"}
  }

  def get(op), do: Map.get(@operators, op)
  def all, do: Map.keys(@operators)
end
```

## Appendix B: Prefer Header Parsing

```elixir
# lib/ex_rest/parser/preferences_parser.ex
defmodule ExRest.Parser.PreferencesParser do
  @moduledoc """
  Parses the Prefer HTTP header.
  """

  alias ExRest.Types.Preferences

  @doc """
  Parses a Prefer header value into a Preferences struct.

  ## Examples

      iex> parse("return=representation, count=exact")
      {:ok, %Preferences{return: :representation, count: :exact}}
  """
  @spec parse(String.t() | nil) :: {:ok, Preferences.t()} | {:error, term()}
  def parse(nil), do: {:ok, %Preferences{}}

  def parse(header) when is_binary(header) do
    prefs =
      header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce(%Preferences{}, &parse_preference/2)

    {:ok, prefs}
  end

  defp parse_preference("return=minimal", acc), do: %{acc | return: :minimal}
  defp parse_preference("return=representation", acc), do: %{acc | return: :representation}
  defp parse_preference("return=headers-only", acc), do: %{acc | return: :headers_only}

  defp parse_preference("count=exact", acc), do: %{acc | count: :exact}
  defp parse_preference("count=planned", acc), do: %{acc | count: :planned}
  defp parse_preference("count=estimated", acc), do: %{acc | count: :estimated}

  defp parse_preference("resolution=merge-duplicates", acc), do: %{acc | resolution: :merge_duplicates}
  defp parse_preference("resolution=ignore-duplicates", acc), do: %{acc | resolution: :ignore_duplicates}

  defp parse_preference("missing=default", acc), do: %{acc | missing: :default}

  defp parse_preference("handling=lenient", acc), do: %{acc | handling: :lenient}
  defp parse_preference("handling=strict", acc), do: %{acc | handling: :strict}

  defp parse_preference("tx=commit", acc), do: %{acc | tx: :commit}
  defp parse_preference("tx=rollback", acc), do: %{acc | tx: :rollback}

  defp parse_preference("max-affected=" <> n, acc) do
    case Integer.parse(n) do
      {num, ""} -> %{acc | max_affected: num}
      _ -> acc
    end
  end

  defp parse_preference("timezone=" <> tz, acc), do: %{acc | timezone: tz}

  defp parse_preference(_, acc), do: acc
end
```

## Appendix C: mix.exs Dependencies

```elixir
defp deps do
  [
    {:nimble_parsec, "~> 1.4"},      # Parser combinators
    {:postgrex, "~> 0.17"},          # PostgreSQL driver
    {:ecto_sql, "~> 3.10"},          # SQL adapter (optional)
    {:plug, "~> 1.14"},              # HTTP middleware
    {:plug_crypto, "~> 2.0"},        # Secure comparisons, timing-safe functions
    {:jason, "~> 1.4"},              # JSON encoding
    {:jose, "~> 1.11"},              # JWT handling
    {:cachex, "~> 3.6"},             # In-memory caching with TTL
    {:telemetry, "~> 1.2"},          # Metrics and instrumentation
    {:hammer, "~> 6.1"},             # Rate limiting

    # Dev/Test
    {:ex_doc, "~> 0.30", only: :dev},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:benchee, "~> 1.1", only: :dev}
  ]
end
```

---
