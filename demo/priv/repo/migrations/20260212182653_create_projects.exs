defmodule Demo.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :name, :string
      add :description, :text
      add :status, :string
      add :archived, :boolean, default: false, null: false
      add :deadline, :date
      add :budget, :decimal

      timestamps(type: :utc_datetime)
    end
  end
end
