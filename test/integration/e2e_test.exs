defmodule PgRest.Integration.E2ETest do
  use PgRest.Integration.Case

  alias Supabase.PostgREST

  defp seed_products(repo) do
    {3, products} =
      repo.insert_all(
        "e2e_products",
        [
          %{name: "Widget A", price: Decimal.new("9.99"), category: "gadgets", active: true},
          %{name: "Widget B", price: Decimal.new("49.99"), category: "electronics", active: true},
          %{name: "Gizmo C", price: Decimal.new("199.99"), category: "electronics", active: false}
        ],
        returning: [:id, :name, :price, :category, :active]
      )

    products
  end

  defp seed_reviews(repo, product_id) do
    {2, reviews} =
      repo.insert_all(
        "e2e_reviews",
        [
          %{body: "Great product!", rating: 5, e2e_product_id: product_id},
          %{body: "Not bad", rating: 3, e2e_product_id: product_id}
        ],
        returning: [:id, :body, :rating, :e2e_product_id]
      )

    reviews
  end

  alias PgRest.Integration.Repo

  describe "read operations" do
    setup %{client: client} do
      products = seed_products(Repo)
      %{products: products, client: client}
    end

    test "list all products", %{client: client, products: products} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert length(resp.body) == length(products)
    end

    test "filter eq", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.eq("category", "electronics")
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert length(resp.body) == 2
      assert Enum.all?(resp.body, &(&1["category"] == "electronics"))
    end

    test "filter range with gt and lt", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.all_of([{:gt, "price", 10}, {:lt, "price", 100}])
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert length(resp.body) == 1
      assert hd(resp.body)["name"] == "Widget B"
    end

    test "filter ilike", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.ilike("name", "%widget%")
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert length(resp.body) == 2
      assert Enum.all?(resp.body, &String.contains?(&1["name"], "Widget"))
    end

    test "order descending", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.order("price")
        |> PostgREST.execute()

      assert resp.status in [200, 206]

      prices =
        resp.body
        |> Enum.map(& &1["price"])
        |> Enum.map(&Decimal.new/1)

      assert prices == Enum.sort(prices, {:desc, Decimal})
    end

    test "limit and offset", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.order("price", asc: true)
        |> PostgREST.limit(2)
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert length(resp.body) == 2

      # Offset by 1 — should skip cheapest, get middle + expensive
      {:ok, resp2} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.order("price", asc: true)
        |> PostgREST.range(1, 2)
        |> PostgREST.execute()

      assert resp2.status in [200, 206]
      assert length(resp2.body) == 2
      assert hd(resp2.body)["name"] == "Widget B"
    end
  end

  describe "select and embed operations" do
    setup %{client: client} do
      [product | _] = products = seed_products(Repo)
      reviews = seed_reviews(Repo, product.id)
      %{products: products, reviews: reviews, product: product, client: client}
    end

    test "select specific columns", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select(["id", "name"], returning: true)
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      first = hd(resp.body)
      assert Map.has_key?(first, "id")
      assert Map.has_key?(first, "name")
      refute Map.has_key?(first, "price")
      refute Map.has_key?(first, "category")
    end

    test "embed has_many — products with reviews", %{client: client, product: product} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select(["*", "e2e_reviews(*)"], returning: true)
        |> PostgREST.eq("id", product.id)
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert [record] = resp.body
      assert is_list(record["e2e_reviews"])
      assert length(record["e2e_reviews"]) == 2
    end

    test "embed belongs_to — reviews with product", %{client: client, product: product} do
      # PostgREST uses table names, but PgRest resolves by Ecto association name.
      # belongs_to :e2e_product → association name is "e2e_product" (singular)
      {:ok, resp} =
        PostgREST.from(client, "e2e_reviews")
        |> PostgREST.select(["*", "e2e_product(*)"], returning: true)
        |> PostgREST.eq("e2e_product_id", product.id)
        |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert length(resp.body) == 2
      first = hd(resp.body)
      assert is_map(first["e2e_product"])
      assert first["e2e_product"]["name"] == product.name
    end
  end

  describe "write operations" do
    test "create single record", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.insert(%{
          "name" => "New Product",
          "price" => "29.99",
          "category" => "gadgets"
        })
        |> PostgREST.execute()

      assert resp.status == 201
      assert [created] = resp.body
      assert created["name"] == "New Product"
    end

    test "update by id", %{client: client} do
      [product | _] = seed_products(Repo)

      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.update(%{"price" => "19.99"})
        |> PostgREST.eq("id", product.id)
        |> PostgREST.execute()

      assert resp.status == 200
      assert [updated] = resp.body
      assert updated["price"] == "19.99"
    end

    test "delete by id", %{client: client} do
      [product | _] = seed_products(Repo)

      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.delete()
        |> PostgREST.eq("id", product.id)
        |> PostgREST.execute()

      assert resp.status == 200
      assert [deleted] = resp.body
      assert deleted["id"] == product.id

      # Verify it's gone
      {:ok, list_resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.eq("id", product.id)
        |> PostgREST.execute()

      assert list_resp.body == []
    end
  end

  describe "bulk operations" do
    test "bulk create", %{client: client} do
      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.insert(%{
          "name" => "Bulk A",
          "price" => "10.00",
          "category" => "bulk"
        })
        |> PostgREST.execute()

      assert resp.status == 201

      {:ok, resp2} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.insert(%{
          "name" => "Bulk B",
          "price" => "20.00",
          "category" => "bulk"
        })
        |> PostgREST.execute()

      assert resp2.status == 201

      # Verify both exist
      {:ok, list_resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.eq("category", "bulk")
        |> PostgREST.execute()

      assert length(list_resp.body) == 2
    end

    test "bulk delete by filter", %{client: client} do
      seed_products(Repo)

      {:ok, resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.delete()
        |> PostgREST.eq("active", "false")
        |> PostgREST.execute()

      assert resp.status == 200
      assert [deleted] = resp.body
      assert deleted["name"] == "Gizmo C"

      # Verify only active products remain
      {:ok, list_resp} =
        PostgREST.from(client, "e2e_products")
        |> PostgREST.select("*", returning: true)
        |> PostgREST.execute()

      assert length(list_resp.body) == 2
      assert Enum.all?(list_resp.body, &(&1["active"] == true))
    end
  end
end
