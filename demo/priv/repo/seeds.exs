alias Demo.Repo
alias Demo.Projects.Project
alias Demo.Tasks.Task

# Clear existing data
Repo.delete_all(Task)
Repo.delete_all(Project)

# --- Projects ---

project_data = [
  %{
    name: "Phoenix LiveView Redesign",
    description:
      "Complete UI overhaul of the admin dashboard using Phoenix LiveView and HEEx components",
    status: "active",
    archived: false,
    deadline: ~D[2026-06-15],
    budget: Decimal.new("50000")
  },
  %{
    name: "PgRest API Layer",
    description:
      "Build a PostgREST-compatible API layer using Plug and Ecto for multi-tenant resource routing",
    status: "active",
    archived: false,
    deadline: ~D[2026-04-30],
    budget: Decimal.new("35000")
  },
  %{
    name: "LiveView Native App",
    description:
      "LiveView Native mobile app with offline ETS sync and Phoenix PubSub notifications",
    status: "active",
    archived: false,
    deadline: ~D[2026-08-01],
    budget: Decimal.new("80000")
  },
  %{
    name: "PgFlow DAG Workers",
    description:
      "Background job processing and DAG workflow orchestration using PgFlow with PostgreSQL-backed queues",
    status: "on_hold",
    archived: false,
    deadline: ~D[2026-09-30],
    budget: Decimal.new("25000")
  },
  %{
    name: "Ueberauth Service",
    description:
      "OAuth2/OIDC authentication service with Ueberauth strategies and Guardian tokens",
    status: "active",
    archived: false,
    deadline: ~D[2026-03-15],
    budget: Decimal.new("40000")
  },
  %{
    name: "Ecto Migration",
    description: "Migrate legacy Django app to Elixir/Phoenix with Ecto multi-tenancy",
    status: "archived",
    archived: true,
    deadline: ~D[2025-12-31],
    budget: Decimal.new("60000")
  },
  %{
    name: "Burrito Releases",
    description:
      "Internal deployment tooling with Burrito single-binary releases and Fly.io infrastructure",
    status: "active",
    archived: false,
    deadline: ~D[2026-05-01],
    budget: Decimal.new("20000")
  }
]

projects =
  Enum.map(project_data, fn data ->
    %Project{}
    |> Project.changeset(data, %{})
    |> Repo.insert!()
  end)

# --- Tasks ---

assignees = [
  "Alice Chen",
  "Bob Martinez",
  "Carol Johnson",
  "Dave Kim",
  "Eve Wilson",
  "Frank Lee",
  "Grace Park"
]

statuses = ["pending", "in_progress", "completed", "cancelled"]
priorities = ["low", "medium", "high", "critical"]

tag_pool = [
  "backend",
  "liveview",
  "database",
  "security",
  "performance",
  "testing",
  "documentation",
  "devops",
  "otp",
  "ux",
  "api",
  "infrastructure"
]

task_templates = [
  {"Set up Mix releases pipeline",
   "Configure GitHub Actions with mix release for automated testing and Fly.io deployment",
   ["devops", "infrastructure"]},
  {"Design Ecto schema",
   "Create ERD and Ecto migrations for the new data model with composite indexes",
   ["database", "backend"]},
  {"Implement Ueberauth flow",
   "OAuth2 login flow with Ueberauth Google and GitHub strategies plus Guardian JWT",
   ["security", "backend", "api"]},
  {"Build LiveView dashboard",
   "Create reusable LiveComponent chart and metric card components with streams",
   ["liveview", "otp"]},
  {"Write API documentation", "OpenAPI 3.0 spec for all PgRest resource endpoints",
   ["documentation", "api"]},
  {"Ecto query audit",
   "Profile and optimize slow Ecto queries with EXPLAIN ANALYZE and pg_stat_statements",
   ["performance", "database"]},
  {"Add Phoenix Channels",
   "Real-time notifications via Phoenix Channels with PubSub presence tracking",
   ["backend", "liveview"]},
  {"Create seed data scripts",
   "Generate realistic test data with ExMachina factories for development",
   ["database", "testing"]},
  {"Implement Hammer rate limiting",
   "Token bucket rate limiting with Hammer for API endpoints and Plug middleware",
   ["security", "api", "backend"]},
  {"Responsive Tailwind layouts",
   "Ensure all LiveView pages work on mobile viewports with Tailwind responsive utilities",
   ["liveview", "ux"]},
  {"Set up Sentry with Logger",
   "Integrate Sentry Elixir SDK with Logger backend for error monitoring and alerting",
   ["devops", "infrastructure"]},
  {"WAL-G backup automation",
   "Automated daily PostgreSQL backups to S3 with WAL-G and pg_dump retention policy",
   ["database", "devops", "infrastructure"]},
  {"ExUnit test coverage",
   "Increase ExUnit test coverage to 80% across all modules with Coveralls integration",
   ["testing", "backend"]},
  {"Absinthe GraphQL endpoint",
   "Add Absinthe GraphQL API alongside PgRest for flexible querying with dataloader",
   ["api", "backend"]},
  {"Accessibility audit", "WCAG 2.1 AA compliance review and LiveView aria attribute fixes",
   ["liveview", "ux"]},
  {"Full-text search with tsvector",
   "PostgreSQL full-text search using tsvector, GIN indexes, and ts_rank ordering",
   ["backend", "database", "performance"]},
  {"Swoosh email system",
   "Transactional email templates with Swoosh adapter and Oban delivery queue",
   ["backend", "infrastructure"]},
  {"CSV export with NimbleCSV",
   "CSV and JSON export for reports using NimbleCSV and Jason streaming encoder",
   ["backend", "api"]},
  {"k6 load testing",
   "k6 load tests for critical Plug endpoints with Ecto connection pool tuning",
   ["testing", "performance"]},
  {"Sobelow security scan",
   "Run Sobelow static analysis and remediate findings across all Phoenix controllers",
   ["security", "testing"]},
  {"Implement Nebulex caching",
   "Nebulex distributed caching with local ETS and partitioned adapter for hot resources",
   ["performance", "backend", "infrastructure"]},
  {"Waffle file uploads",
   "S3-backed file uploads with Waffle and Mogrify image processing pipeline",
   ["backend", "api", "infrastructure"]},
  {"LiveView admin CRUD",
   "Back-office admin interface with LiveView table components and inline editing",
   ["liveview", "backend"]},
  {"Structured logging with Logfmt",
   "Structured logging with Logger metadata, Logfmt formatter, and Grafana dashboards",
   ["devops", "infrastructure"]},
  {"API versioning with Plug.Router",
   "Implement URL-based API versioning using Plug.Router scopes with deprecation notices",
   ["api", "backend", "documentation"]}
]

now = DateTime.utc_now() |> DateTime.truncate(:second)

for i <- 1..120 do
  project = Enum.random(projects)
  {title_base, desc_base, base_tags} = Enum.random(task_templates)

  # Add some variety to titles
  title = if rem(i, 3) == 0, do: "#{title_base} (phase #{rem(i, 4) + 1})", else: title_base

  status = Enum.random(statuses)
  priority = Enum.random(priorities)
  assignee = Enum.random(assignees)

  # Mix in some extra random tags
  extra_tags = Enum.take_random(tag_pool -- base_tags, :rand.uniform(2) - 1)
  tags = Enum.uniq(base_tags ++ extra_tags)

  # Spread due dates across several months
  days_offset = :rand.uniform(180) - 30
  due_date = Date.add(~D[2026-02-01], days_offset)

  estimated_hours = Decimal.new("#{:rand.uniform(40) + 1}")
  completed = status == "completed"
  urgent = priority == "critical" or (priority == "high" and :rand.uniform(3) == 1)
  complexity = :rand.uniform(10)

  # Some tasks are soft-deleted
  deleted_at = if status == "cancelled" and :rand.uniform(3) == 1, do: now, else: nil

  %Task{}
  |> Task.changeset(
    %{
      title: title,
      description: desc_base,
      status: status,
      priority: priority,
      assignee_name: assignee,
      tags: tags,
      due_date: due_date,
      estimated_hours: estimated_hours,
      completed: completed,
      urgent: urgent,
      complexity: complexity,
      deleted_at: deleted_at,
      project_id: project.id
    },
    %{}
  )
  |> Repo.insert!()
end

IO.puts("Seeded #{length(projects)} projects and 120 tasks")
