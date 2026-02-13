defmodule PgRest.Test.Order do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Query

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "orders" do
    field(:reference, :string)
    field(:status, :string)
    field(:total, :decimal)
    field(:tenant_id, :integer)
    has_many(:line_items, PgRest.Test.LineItem)
  end

  @impl PgRest.Resource
  def scope(query, %{tenant_id: tid}) do
    where(query, [r], r.tenant_id == ^tid)
  end

  def scope(query, _context), do: query
end

defmodule PgRest.Test.LineItem do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "line_items" do
    field(:name, :string)
    field(:quantity, :integer)
    field(:price, :decimal)
    belongs_to(:order, PgRest.Test.Order)
  end
end

defmodule PgRest.Test.Product do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "products" do
    field(:name, :string)
    field(:price, :decimal)
  end
end

defmodule PgRest.Test.NonResource do
  @moduledoc false
  use Ecto.Schema

  schema "non_resources" do
    field(:name, :string)
  end
end

defmodule PgRest.Test.ReadOnlyProduct do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, allow: [:read]

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "products" do
    field(:name, :string)
    field(:price, :decimal)
  end
end

defmodule PgRest.Test.NoDeleteOrder do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, allow: [:read, :create, :update]

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "orders" do
    field(:reference, :string)
    field(:status, :string)
    field(:total, :decimal)
    field(:tenant_id, :integer)
  end
end

# --- Schemas with associations for embedding tests ---

defmodule PgRest.Test.Author do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "authors" do
    field(:first_name, :string)
    field(:last_name, :string)
    has_many(:posts, PgRest.Test.Post)
  end
end

defmodule PgRest.Test.Post do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "posts" do
    field(:title, :string)
    field(:body, :string)
    field(:status, :string)
    belongs_to(:author, PgRest.Test.Author)
    has_many(:comments, PgRest.Test.Comment)
    many_to_many(:tags, PgRest.Test.Tag, join_through: "posts_tags")
  end
end

defmodule PgRest.Test.Comment do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "comments" do
    field(:body, :string)
    field(:status, :string)
    belongs_to(:post, PgRest.Test.Post)
  end
end

defmodule PgRest.Test.Tag do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "tags" do
    field(:name, :string)
    many_to_many(:posts, PgRest.Test.Post, join_through: "posts_tags")
  end
end

# --- Self-referential schema ---

defmodule PgRest.Test.Category do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "categories" do
    field(:name, :string)
    belongs_to(:parent, PgRest.Test.Category)
    has_many(:children, PgRest.Test.Category, foreign_key: :parent_id)
  end
end

# --- Multiple FKs to same table ---

defmodule PgRest.Test.Address do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "addresses" do
    field(:street, :string)
    field(:city, :string)
  end
end

defmodule PgRest.Test.ShippingOrder do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "shipping_orders" do
    field(:reference, :string)
    belongs_to(:billing_address, PgRest.Test.Address)
    belongs_to(:shipping_address, PgRest.Test.Address)
  end
end
