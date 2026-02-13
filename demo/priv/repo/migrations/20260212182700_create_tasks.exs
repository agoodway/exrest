defmodule Demo.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string
      add :description, :text
      add :status, :string
      add :priority, :string
      add :assignee_name, :string
      add :tags, {:array, :string}
      add :due_date, :date
      add :estimated_hours, :decimal
      add :completed, :boolean, default: false, null: false
      add :urgent, :boolean, default: false, null: false
      add :complexity, :integer
      add :deleted_at, :utc_datetime
      add :project_id, references(:projects, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:project_id])
  end
end
