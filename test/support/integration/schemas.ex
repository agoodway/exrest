defmodule PgRest.Integration.E2EProduct do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Changeset

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "e2e_products" do
    field(:name, :string)
    field(:price, :decimal)
    field(:category, :string)
    field(:active, :boolean, default: true)
    has_many(:e2e_reviews, PgRest.Integration.E2EReview, foreign_key: :e2e_product_id)
  end

  @impl PgRest.Resource
  def changeset(struct, attrs, _context) do
    struct
    |> cast(attrs, [:name, :price, :category, :active])
    |> validate_required([:name])
  end
end

defmodule PgRest.Integration.E2EReview do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Changeset

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "e2e_reviews" do
    field(:body, :string)
    field(:rating, :integer)
    belongs_to(:e2e_product, PgRest.Integration.E2EProduct)
  end

  @impl PgRest.Resource
  def changeset(struct, attrs, _context) do
    struct
    |> cast(attrs, [:body, :rating, :e2e_product_id])
    |> validate_required([:body, :rating])
  end
end
