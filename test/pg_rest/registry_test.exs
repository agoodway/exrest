defmodule PgRest.RegistryTest do
  use ExUnit.Case

  setup do
    start_supervised!(
      {PgRest.Registry,
       modules: [PgRest.Test.Order, PgRest.Test.Product, PgRest.Test.NonResource]}
    )

    :ok
  end

  describe "get_resource/1" do
    test "finds resource by table name" do
      assert {:ok, config} = PgRest.Registry.get_resource("orders")
      assert config.module == PgRest.Test.Order
      assert config.table == "orders"
      assert :status in config.fields
    end

    test "finds resource by module" do
      assert {:ok, config} = PgRest.Registry.get_resource(PgRest.Test.Product)
      assert config.module == PgRest.Test.Product
      assert config.table == "products"
    end

    test "returns error for unknown table" do
      assert {:error, :not_found} = PgRest.Registry.get_resource("nonexistent")
    end

    test "returns error for non-resource module" do
      assert {:error, :not_found} = PgRest.Registry.get_resource(PgRest.Test.NonResource)
    end
  end

  describe "list_resources/0" do
    test "returns all registered resources" do
      resources = PgRest.Registry.list_resources()
      tables = Enum.map(resources, & &1.table)
      assert "orders" in tables
      assert "products" in tables
    end
  end
end
