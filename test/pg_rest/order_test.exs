defmodule PgRest.OrderTest do
  use ExUnit.Case

  alias PgRest.Order

  describe "apply_order/2" do
    test "nil directives returns query unchanged" do
      query = Order.apply_order(PgRest.Test.Order, nil)
      assert query == PgRest.Test.Order
    end

    test "single asc order" do
      directives = [%{field: "reference", direction: :asc, nulls: nil}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [asc: _]}] = query.order_bys
    end

    test "single desc order" do
      directives = [%{field: "reference", direction: :desc, nulls: nil}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [desc: _]}] = query.order_bys
    end

    test "asc with nulls_first" do
      directives = [%{field: "reference", direction: :asc, nulls: :first}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [asc_nulls_first: _]}] = query.order_bys
    end

    test "asc with nulls_last" do
      directives = [%{field: "reference", direction: :asc, nulls: :last}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [asc_nulls_last: _]}] = query.order_bys
    end

    test "desc with nulls_first" do
      directives = [%{field: "reference", direction: :desc, nulls: :first}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [desc_nulls_first: _]}] = query.order_bys
    end

    test "desc with nulls_last" do
      directives = [%{field: "reference", direction: :desc, nulls: :last}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [desc_nulls_last: _]}] = query.order_bys
    end

    test "multiple order directives (compound)" do
      directives = [
        %{field: "status", direction: :asc, nulls: nil},
        %{field: "total", direction: :desc, nulls: :last}
      ]

      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert length(query.order_bys) == 2
      assert [%{expr: [asc: _]}, %{expr: [desc_nulls_last: _]}] = query.order_bys
    end

    test "atom field passes through" do
      directives = [%{field: :reference, direction: :asc, nulls: nil}]
      query = Order.apply_order(PgRest.Test.Order, directives)
      assert %Ecto.Query{} = query
      assert [%{expr: [asc: _]}] = query.order_bys
    end
  end
end
