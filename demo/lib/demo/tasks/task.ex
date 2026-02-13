defmodule Demo.Tasks.Task do
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Changeset
  import Ecto.Query

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string
    field :priority, :string
    field :assignee_name, :string
    field :tags, {:array, :string}
    field :due_date, :date
    field :estimated_hours, :decimal
    field :completed, :boolean, default: false
    field :urgent, :boolean, default: false
    field :complexity, :integer
    field :deleted_at, :utc_datetime

    belongs_to :project, Demo.Projects.Project

    timestamps(type: :utc_datetime)
  end

  @impl PgRest.Resource
  def changeset(task, attrs, _context) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :assignee_name,
      :tags,
      :due_date,
      :estimated_hours,
      :completed,
      :urgent,
      :complexity,
      :deleted_at,
      :project_id
    ])
    |> validate_required([:title, :status])
    |> validate_inclusion(:status, ~w(pending in_progress completed cancelled))
    |> then(fn cs ->
      if get_change(cs, :priority),
        do: validate_inclusion(cs, :priority, ~w(low medium high critical)),
        else: cs
    end)
  end

  # Exclude soft-deleted tasks by default
  @impl PgRest.Resource
  def scope(query, _context) do
    where(query, [t], is_nil(t.deleted_at))
  end

  @impl PgRest.Resource
  def handle_param("search", value, query, _context) do
    pattern = "%#{value}%"
    where(query, [t], ilike(t.title, ^pattern) or ilike(t.description, ^pattern))
  end

  def handle_param(_key, _value, query, _context), do: query
end
