defmodule PgRest.Integration.Migration do
  @moduledoc false
  use Ecto.Migration

  def change do
    create_if_not_exists table(:e2e_products) do
      add(:name, :string, null: false)
      add(:price, :decimal)
      add(:category, :string)
      add(:active, :boolean, default: true)
    end

    create_if_not_exists table(:e2e_reviews) do
      add(:body, :string, null: false)
      add(:rating, :integer, null: false)
      add(:e2e_product_id, references(:e2e_products, on_delete: :delete_all), null: false)
    end
  end
end
