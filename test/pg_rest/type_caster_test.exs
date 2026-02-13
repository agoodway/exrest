defmodule PgRest.TypeCasterTest do
  use ExUnit.Case

  alias PgRest.TypeCaster

  describe "cast_filters/2" do
    test "casts integer field from string" do
      filters = [%{field: "tenant_id", operator: :eq, value: "42"}]
      assert {:ok, [%{value: 42}]} = TypeCaster.cast_filters(filters, PgRest.Test.Order)
    end

    test "casts decimal field from string" do
      filters = [%{field: "total", operator: :gt, value: "100.50"}]
      assert {:ok, [%{value: value}]} = TypeCaster.cast_filters(filters, PgRest.Test.Order)
      assert Decimal.equal?(value, Decimal.new("100.50"))
    end

    test "leaves string fields as-is" do
      filters = [%{field: "status", operator: :eq, value: "active"}]
      assert {:ok, [%{value: "active"}]} = TypeCaster.cast_filters(filters, PgRest.Test.Order)
    end

    test "casts in operator values" do
      filters = [%{field: "tenant_id", operator: :in, value: ["1", "2", "3"]}]
      assert {:ok, [%{value: [1, 2, 3]}]} = TypeCaster.cast_filters(filters, PgRest.Test.Order)
    end

    test "skips casting for FTS operators" do
      filters = [%{field: "status", operator: :fts, value: {"english", "test"}}]

      assert {:ok, [%{value: {"english", "test"}}]} =
               TypeCaster.cast_filters(filters, PgRest.Test.Order)
    end

    test "skips casting for is_null" do
      filters = [%{field: "status", operator: :is_null, value: true}]
      assert {:ok, [%{value: true}]} = TypeCaster.cast_filters(filters, PgRest.Test.Order)
    end

    test "handles logical AND filters" do
      filters = [
        %{
          logic: :and,
          conditions: [
            %{field: "tenant_id", operator: :eq, value: "42"},
            %{field: "status", operator: :eq, value: "active"}
          ]
        }
      ]

      assert {:ok, [%{logic: :and, conditions: conditions}]} =
               TypeCaster.cast_filters(filters, PgRest.Test.Order)

      assert [%{value: 42}, %{value: "active"}] = conditions
    end

    test "handles logical OR filters" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "tenant_id", operator: :eq, value: "1"},
            %{field: "tenant_id", operator: :eq, value: "2"}
          ]
        }
      ]

      assert {:ok, [%{logic: :or, conditions: conditions}]} =
               TypeCaster.cast_filters(filters, PgRest.Test.Order)

      assert [%{value: 1}, %{value: 2}] = conditions
    end

    test "handles NOT filter" do
      filters = [%{logic: :not, condition: %{field: "tenant_id", operator: :eq, value: "42"}}]

      assert {:ok, [%{logic: :not, condition: %{value: 42}}]} =
               TypeCaster.cast_filters(filters, PgRest.Test.Order)
    end

    test "empty filters returns empty list" do
      assert {:ok, []} = TypeCaster.cast_filters([], PgRest.Test.Order)
    end
  end
end
