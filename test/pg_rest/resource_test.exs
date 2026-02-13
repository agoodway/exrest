defmodule PgRest.ResourceTest do
  use ExUnit.Case
  import Ecto.Query

  alias PgRest.Test.{NoDeleteOrder, Order, Product, ReadOnlyProduct}

  describe "__pgrest_resource__/0" do
    test "returns true for resource modules" do
      assert Order.__pgrest_resource__() == true
      assert Product.__pgrest_resource__() == true
    end
  end

  describe "__pgrest_config__/0" do
    test "returns config with module, table, fields" do
      config = Order.__pgrest_config__()

      assert config.module == Order
      assert config.table == "orders"
      assert :reference in config.fields
      assert :status in config.fields
      assert :total in config.fields
      assert config.primary_key == [:id]
    end

    test "non-resource modules don't have pgrest functions" do
      refute function_exported?(PgRest.Test.NonResource, :__pgrest_resource__, 0)
    end
  end

  describe "default callbacks" do
    test "scope/2 returns query unchanged by default" do
      query = Product
      assert Product.scope(query, %{}) == query
    end

    test "handle_param/4 returns query unchanged by default" do
      query = Product
      assert Product.handle_param("foo", "bar", query, %{}) == query
    end

    test "changeset/3 returns a changeset by default" do
      cs = Product.changeset(%Product{}, %{name: "test"}, %{})
      assert %Ecto.Changeset{} = cs
    end

    test "after_load/2 returns record unchanged by default" do
      record = %Product{name: "test"}
      assert Product.after_load(record, %{}) == record
    end
  end

  describe "overridden callbacks" do
    test "scope/2 can be overridden" do
      query = Order |> from(as: :order)
      scoped = Order.scope(query, %{tenant_id: 42})
      assert %Ecto.Query{} = scoped
    end
  end

  describe "allow option" do
    test "default allow is :all in config" do
      config = Product.__pgrest_config__()
      assert config.allow == :all
    end

    test "restricted allow stored correctly in config" do
      config = ReadOnlyProduct.__pgrest_config__()
      assert config.allow == [:read]

      config = NoDeleteOrder.__pgrest_config__()
      assert config.allow == [:read, :create, :update]
    end

    test "compile-time validation rejects invalid operations" do
      assert_raise ArgumentError, ~r/invalid operations in :allow option/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.InvalidOps do
          use Ecto.Schema
          use PgRest.Resource, allow: [:read, :invalid_op]

          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end

    test "compile-time validation rejects non-list/non-:all values" do
      assert_raise ArgumentError, ~r/invalid :allow option/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.InvalidAllow do
          use Ecto.Schema
          use PgRest.Resource, allow: "read"

          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end

    test "compile-time validation rejects empty list" do
      assert_raise ArgumentError, ~r/:allow option cannot be an empty list/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.EmptyAllow do
          use Ecto.Schema
          use PgRest.Resource, allow: []

          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end

    test "explicit :all is accepted" do
      config = Order.__pgrest_config__()
      assert config.allow == :all
    end
  end
end
