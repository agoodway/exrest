defmodule DemoWeb.HomeLive do
  use DemoWeb, :live_view

  @queries [
    %{
      id: "equality",
      filter: "Equality",
      ecto: "==",
      path: "/api/tasks?status=eq.pending",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select()\n    .eq('status', 'pending')",
      table: "tasks",
      chain: [["eq", ["status", "pending"]]]
    },
    %{
      id: "neq",
      filter: "Not equal",
      ecto: "!=",
      path: "/api/projects?status=neq.archived",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select()\n    .neq('status', 'archived')",
      table: "projects",
      chain: [["neq", ["status", "archived"]]]
    },
    %{
      id: "gte",
      filter: "Greater than or equal",
      ecto: ">=",
      path: "/api/projects?budget=gte.50000",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select()\n    .gte('budget', '50000')",
      table: "projects",
      chain: [["gte", ["budget", "50000"]]]
    },
    %{
      id: "lt",
      filter: "Less than",
      ecto: "<",
      path: "/api/tasks?complexity=lt.3",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select()\n    .lt('complexity', '3')",
      table: "tasks",
      chain: [["lt", ["complexity", "3"]]]
    },
    %{
      id: "is",
      filter: "Boolean (IS)",
      ecto: "==",
      path: "/api/projects?archived=is.false",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select()\n    .is('archived', false)",
      table: "projects",
      chain: [["is", ["archived", "false"]]]
    },
    %{
      id: "ilike",
      filter: "Pattern match (ILIKE)",
      ecto: "ilike/2",
      path: "/api/projects?name=ilike.*API*",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select()\n    .ilike('name', '*API*')",
      table: "projects",
      chain: [["ilike", ["name", "*API*"]]]
    },
    %{
      id: "in",
      filter: "IN list",
      ecto: "in/2",
      path: "/api/tasks?status=in.(pending,in_progress)",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select()\n    .in('status', ['pending', 'in_progress'])",
      table: "tasks",
      chain: [["in", ["status", ["pending", "in_progress"]]]]
    },
    %{
      id: "cs",
      filter: "Array contains",
      ecto: ~s|fragment("@>")|,
      path: "/api/tasks?tags=cs.{backend}",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select()\n    .contains('tags', ['backend'])",
      table: "tasks",
      chain: [["contains", ["tags", ["backend"]]]]
    },
    %{
      id: "order",
      filter: "Ordering",
      ecto: "order_by/2",
      path: "/api/projects?order=budget.desc",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select()\n    .order('budget', { ascending: false })",
      table: "projects",
      chain: [["order", ["budget", %{"ascending" => false}]]]
    },
    %{
      id: "pagination",
      filter: "Pagination",
      ecto: "limit/2, offset/2",
      path: "/api/tasks?limit=5&offset=0",
      code: "const { data } = await postgrest\n    .from('tasks')\n    .select()\n    .limit(5)",
      table: "tasks",
      chain: [["limit", [5]]]
    },
    %{
      id: "select",
      filter: "Select fields",
      ecto: "select/3",
      path: "/api/projects?select=name,status,budget",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select('name,status,budget')",
      table: "projects",
      select: "name,status,budget",
      chain: []
    },
    %{
      id: "combined",
      filter: "Combined",
      ecto: "==, >=, order_by/2, limit/2",
      path: "/api/tasks?status=eq.pending&priority=eq.high&order=due_date.asc&limit=10",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select()\n    .eq('status', 'pending')\n    .eq('priority', 'high')\n    .order('due_date', { ascending: true })\n    .limit(10)",
      table: "tasks",
      chain: [
        ["eq", ["status", "pending"]],
        ["eq", ["priority", "high"]],
        ["order", ["due_date", %{"ascending" => true}]],
        ["limit", [10]]
      ]
    },
    %{
      id: "embed",
      filter: "Embed (has_many)",
      ecto: "preload/2",
      path: "/api/projects?select=name,status,tasks(title,status,priority)",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select('name,status,tasks(title,status,priority)')",
      table: "projects",
      select: "name,status,tasks(title,status,priority)",
      chain: []
    },
    %{
      id: "embed-parent",
      filter: "Embed (belongs_to)",
      ecto: "preload/2",
      path: "/api/tasks?select=title,status,project(name,status)",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select('title,status,project(name,status)')",
      table: "tasks",
      select: "title,status,project(name,status)",
      chain: []
    },
    %{
      id: "inner-join",
      filter: "Inner join (!inner)",
      ecto: "join/5, where/3",
      path: "/api/tasks?select=title,priority,project!inner(name)&project.status=eq.active",
      code:
        "const { data } = await postgrest\n    .from('tasks')\n    .select('title,priority,project!inner(name)')\n    .eq('project.status', 'active')",
      table: "tasks",
      select: "title,priority,project!inner(name)",
      chain: [["eq", ["project.status", "active"]]]
    },
    %{
      id: "embed-filter",
      filter: "Embed filter",
      ecto: "preload + where/3",
      path: "/api/projects?select=name,tasks(title,priority)&tasks.status=eq.pending",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select('name,tasks(title,priority)')\n    .eq('tasks.status', 'pending')",
      table: "projects",
      select: "name,tasks(title,priority)",
      chain: [["eq", ["tasks.status", "pending"]]]
    },
    %{
      id: "embed-order",
      filter: "Embed ordering",
      ecto: "preload + order_by + limit",
      path:
        "/api/projects?select=name,tasks(title,priority)&tasks.order=priority.desc&tasks.limit=3",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select('name,tasks(title,priority)')\n    .order('priority', { referencedTable: 'tasks', ascending: false })\n    .limit(3, { referencedTable: 'tasks' })",
      table: "projects",
      select: "name,tasks(title,priority)",
      chain: [
        ["order", ["priority", %{"referencedTable" => "tasks", "ascending" => false}]],
        ["limit", [3, %{"referencedTable" => "tasks"}]]
      ]
    },
    %{
      id: "search",
      filter: "Custom search",
      ecto: "ilike/2",
      path: "/api/projects?search=Phoenix",
      code:
        "const { data } = await postgrest\n    .from('projects')\n    .select()\n\n// PgRest custom param appended to the\n// postgrest-js URL: ?search=Phoenix\n// Separated from filters as custom_params",
      table: "projects",
      params: %{"search" => "Phoenix"},
      chain: []
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "PgRest Demo",
       queries: @queries,
       response: nil,
       active_query_id: nil,
       loading: false,
       timing: nil,
       sql_queries: []
     )}
  end

  @impl true
  def handle_event("run_query", %{"id" => id}, socket) do
    query = Enum.find(@queries, &(&1.id == id))

    socket =
      socket
      |> assign(active_query_id: id, loading: true, response: nil, timing: nil, sql_queries: [])
      |> push_event("execute", %{
        table: query.table,
        select: Map.get(query, :select, "*"),
        chain: query.chain,
        params: Map.get(query, :params, %{})
      })

    {:noreply, socket}
  end

  def handle_event("query_result", %{"data" => data, "timing" => timing} = params, socket) do
    response = Jason.encode!(data, pretty: true)
    sql_queries = Map.get(params, "queries", [])

    {:noreply,
     assign(socket,
       response: response,
       loading: false,
       timing: parse_timing(timing),
       sql_queries: sql_queries
     )}
  end

  def handle_event("query_result", %{"error" => error, "timing" => timing} = params, socket) do
    response = Jason.encode!(error, pretty: true)
    sql_queries = Map.get(params, "queries", [])

    {:noreply,
     assign(socket,
       response: {:error, response},
       loading: false,
       timing: parse_timing(timing),
       sql_queries: sql_queries
     )}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply,
     assign(socket,
       active_query_id: nil,
       response: nil,
       loading: false,
       timing: nil,
       sql_queries: []
     )}
  end

  defp parse_timing(%{"client_ms" => client, "server_ms" => server}) do
    %{client_ms: client, server_ms: server}
  end

  defp timing_bar(assigns) do
    ~H"""
    <%= if @timing do %>
      <div class="flex justify-end gap-3 px-4 pb-2 text-xs opacity-50">
        <%= if @timing.server_ms do %>
          <span>Server {@timing.server_ms}ms</span>
        <% end %>
        <span>Round-trip {@timing.client_ms}ms</span>
      </div>
    <% end %>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold">PgRest Demo</h1>
            <p class="mt-2 text-base-content/70">
              A PostgREST and Supabase-compatible REST API powered by Elixir and Ecto.
            </p>
          </div>
          <a
            href="https://github.com/agoodway/pgrest"
            class="btn btn-sm btn-outline gap-2"
            target="_blank"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
            </svg>
            GitHub
          </a>
        </div>

        <div class="divider"></div>

        <h2 class="text-xl font-semibold">Example Queries</h2>
        <p class="text-base text-base-content/70">
          Click a play button to execute the PgRest query, which uses the
          <a
            href="https://github.com/supabase/supabase-js"
            target="_blank"
            rel="noopener"
            class="badge badge-ghost badge-lg link"
          >
            @supabase/postgrest-js
          </a>
          client in your browser.
        </p>
        <div class="overflow-x-auto">
          <table class="table table-md text-base">
            <thead>
              <tr>
                <th>Run</th>
                <th>Filter</th>
                <th>Ecto</th>
                <th>Example</th>
              </tr>
            </thead>
            <tbody id="supabase-query" phx-hook="SupabaseQuery">
              <%= for q <- @queries do %>
                <tr class={@active_query_id == q.id && "bg-base-200"}>
                  <td>
                    <button
                      phx-click="run_query"
                      phx-value-id={q.id}
                      class="btn btn-circle btn-ghost btn-sm"
                    >
                      <.icon name="hero-play-solid" class="size-4 text-success" />
                    </button>
                  </td>
                  <td>{q.filter}</td>
                  <td><code>{q.ecto}</code></td>
                  <td>
                    <a
                      href={q.path}
                      class="link link-primary font-mono text-sm"
                      target="_blank"
                      rel="noopener"
                    >
                      {q.path}
                    </a>
                  </td>
                </tr>
                <%= if @active_query_id == q.id do %>
                  <tr class="bg-base-200">
                    <td colspan="4" class="p-4">
                      <div
                        id={"terminal-#{q.id}"}
                        phx-hook="Highlight"
                        class="relative mockup-code text-sm bg-[#1a1a2e] group/terminal before:hidden"
                      >
                        <div
                          class="absolute top-0 left-0 right-0 h-8 cursor-default z-10"
                          phx-click="close_panel"
                        >
                          <div class="absolute top-[0.65rem] left-4 flex gap-1.5 z-20 items-center">
                            <span class="inline-block w-3 h-3 rounded-full bg-neutral-content/20">
                            </span>
                            <span class="inline-flex items-center justify-center w-3 h-3 rounded-full bg-neutral-content/20 group-hover/terminal:bg-[#febc2e] transition-colors text-[10px] leading-none font-bold text-transparent group-hover/terminal:text-black/60 -translate-x-px">
                              &ndash;
                            </span>
                            <span class="inline-block w-3 h-3 rounded-full bg-neutral-content/20">
                            </span>
                          </div>
                        </div>
                        <div class="pt-4 pb-2">
                          <div class="flex justify-end pr-4 pb-1">
                            <span class="text-xs text-neutral-content/30 uppercase tracking-wider">
                              Postgrest-js Request
                            </span>
                          </div>
                          <div class="max-h-48 overflow-y-auto px-6">
                            <pre class="!p-0 before:hidden whitespace-pre-wrap break-words"><code class="language-javascript text-sm">{q.code}</code></pre>
                          </div>
                        </div>
                        <%= if @sql_queries != [] do %>
                          <div class="border-t border-white/10 mt-2 pt-2 pb-2">
                            <div class="flex justify-end pr-4 pb-1">
                              <span class="text-xs text-neutral-content/30 uppercase tracking-wider">
                                Generated SQL
                              </span>
                            </div>
                            <%= for query_sql <- @sql_queries do %>
                              <div class="overflow-y-auto px-6">
                                <pre class="!p-0 before:hidden whitespace-pre-wrap break-words"><code class="language-sql text-sm">{query_sql}</code></pre>
                              </div>
                            <% end %>
                          </div>
                        <% end %>
                        <%= if @loading do %>
                          <div class="flex items-center justify-center py-6">
                            <span class="loading loading-spinner loading-md"></span>
                          </div>
                        <% else %>
                          <%= case @response do %>
                            <% {:error, error_json} -> %>
                              <div class="border-t border-white/10 mt-2 pt-2 pb-2">
                                <div class="flex justify-end pr-4 pb-1">
                                  <span class="text-xs text-neutral-content/30 uppercase tracking-wider">
                                    PgRest Response
                                  </span>
                                </div>
                                <div class="max-h-96 overflow-y-auto px-6">
                                  <pre class="!p-0 before:hidden whitespace-pre"><code class="language-json text-error text-sm">{error_json}</code></pre>
                                </div>
                                <.timing_bar timing={@timing} />
                              </div>
                            <% json when is_binary(json) -> %>
                              <div class="border-t border-white/10 mt-2 pt-2 pb-2">
                                <div class="flex justify-end pr-4 pb-1">
                                  <span class="text-xs text-neutral-content/30 uppercase tracking-wider">
                                    PgRest Response
                                  </span>
                                </div>
                                <div class="max-h-96 overflow-y-auto px-6">
                                  <pre class="!p-0 before:hidden whitespace-pre"><code class="language-json text-sm">{json}</code></pre>
                                </div>
                                <.timing_bar timing={@timing} />
                              </div>
                            <% nil -> %>
                          <% end %>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>

        <footer class="pt-8 pb-4 text-center text-sm text-base-content/50">
          A project by
          <a href="https://goodway.dev" target="_blank" rel="noopener" class="link">Goodway</a>
          — we build software that drives results.
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
