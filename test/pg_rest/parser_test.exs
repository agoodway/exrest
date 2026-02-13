defmodule PgRest.ParserTest do
  use ExUnit.Case

  alias PgRest.Parser

  describe "parse_operator_value/1" do
    test "parses eq operator" do
      assert {:ok, :eq, "active"} = Parser.parse_operator_value("eq.active")
    end

    test "parses neq operator" do
      assert {:ok, :neq, "deleted"} = Parser.parse_operator_value("neq.deleted")
    end

    test "parses gt operator" do
      assert {:ok, :gt, "100"} = Parser.parse_operator_value("gt.100")
    end

    test "parses gte operator" do
      assert {:ok, :gte, "100"} = Parser.parse_operator_value("gte.100")
    end

    test "parses lt operator" do
      assert {:ok, :lt, "50"} = Parser.parse_operator_value("lt.50")
    end

    test "parses lte operator" do
      assert {:ok, :lte, "50"} = Parser.parse_operator_value("lte.50")
    end

    test "parses like operator" do
      assert {:ok, :like, "%test%"} = Parser.parse_operator_value("like.%test%")
    end

    test "parses ilike operator" do
      assert {:ok, :ilike, "*smith*"} = Parser.parse_operator_value("ilike.*smith*")
    end

    test "parses match operator" do
      assert {:ok, :match, "^ORD-\\d+"} = Parser.parse_operator_value("match.^ORD-\\d+")
    end

    test "parses imatch operator" do
      assert {:ok, :imatch, "^ord"} = Parser.parse_operator_value("imatch.^ord")
    end

    test "parses in operator" do
      assert {:ok, :in, ["active", "pending", "shipped"]} =
               Parser.parse_operator_value("in.(active,pending,shipped)")
    end

    test "parse_in_value rejects missing closing paren" do
      assert {:error, {:invalid_in, _}} = Parser.parse_operator_value("in.(a,b")
    end

    test "parse_in_value strips exactly one trailing paren" do
      # "in.(a,b))" should fail because the parser matches "in.(" prefix
      # leaving "a,b))" — binary match expects exactly one trailing ")"
      assert {:ok, :in, ["a", "b)"]} = Parser.parse_operator_value("in.(a,b))")
    end

    test "parses is.null" do
      assert {:ok, :is_null, true} = Parser.parse_operator_value("is.null")
    end

    test "parses is.not_null" do
      assert {:ok, :is_null, false} = Parser.parse_operator_value("is.not_null")
    end

    test "parses is.true" do
      assert {:ok, :is, true} = Parser.parse_operator_value("is.true")
    end

    test "parses is.false" do
      assert {:ok, :is, false} = Parser.parse_operator_value("is.false")
    end

    test "parses is.unknown as is_null" do
      assert {:ok, :is_null, true} = Parser.parse_operator_value("is.unknown")
    end

    test "parses cs (contains) operator" do
      assert {:ok, :cs, "{elixir,phoenix}"} = Parser.parse_operator_value("cs.{elixir,phoenix}")
    end

    test "parses cd (contained by) operator" do
      assert {:ok, :cd, "{a,b,c}"} = Parser.parse_operator_value("cd.{a,b,c}")
    end

    test "parses ov (overlap) operator" do
      assert {:ok, :ov, "{a,b}"} = Parser.parse_operator_value("ov.{a,b}")
    end

    test "parses isdistinct operator" do
      assert {:ok, :isdistinct, "active"} = Parser.parse_operator_value("isdistinct.active")
    end

    test "parses sl (strictly left) operator" do
      assert {:ok, :sl, "[1,5]"} = Parser.parse_operator_value("sl.[1,5]")
    end

    test "parses sr (strictly right) operator" do
      assert {:ok, :sr, "[1,5]"} = Parser.parse_operator_value("sr.[1,5]")
    end

    test "parses nxr operator" do
      assert {:ok, :nxr, "[1,5]"} = Parser.parse_operator_value("nxr.[1,5]")
    end

    test "parses nxl operator" do
      assert {:ok, :nxl, "[1,5]"} = Parser.parse_operator_value("nxl.[1,5]")
    end

    test "parses adj (adjacent) operator" do
      assert {:ok, :adj, "[1,5]"} = Parser.parse_operator_value("adj.[1,5]")
    end

    test "parses fts operator with default english" do
      assert {:ok, :fts, {"english", "fat cats"}} = Parser.parse_operator_value("fts.fat cats")
    end

    test "parses fts with language config" do
      assert {:ok, :fts, {"french", "chat"}} = Parser.parse_operator_value("fts(french).chat")
    end

    test "parses plfts operator" do
      assert {:ok, :plfts, {"english", "fat cats"}} =
               Parser.parse_operator_value("plfts.fat cats")
    end

    test "parses plfts with language config" do
      assert {:ok, :plfts, {"german", "katze"}} =
               Parser.parse_operator_value("plfts(german).katze")
    end

    test "parses phfts operator" do
      assert {:ok, :phfts, {"english", "fat cats"}} =
               Parser.parse_operator_value("phfts.fat cats")
    end

    test "parses phfts with language config" do
      assert {:ok, :phfts, {"spanish", "gatos"}} =
               Parser.parse_operator_value("phfts(spanish).gatos")
    end

    test "parses wfts operator" do
      assert {:ok, :wfts, {"english", "fat cats"}} = Parser.parse_operator_value("wfts.fat cats")
    end

    test "parses wfts with language config" do
      assert {:ok, :wfts, {"french", "chat gros"}} =
               Parser.parse_operator_value("wfts(french).chat gros")
    end

    test "returns error for invalid operator" do
      assert {:error, {:invalid_operator, "badop.value"}} =
               Parser.parse_operator_value("badop.value")
    end

    test "returns error for invalid is value" do
      assert {:error, {:invalid_is, "maybe"}} = Parser.parse_operator_value("is.maybe")
    end

    test "returns error for invalid fts config" do
      assert {:error, {:invalid_fts, _}} = Parser.parse_operator_value("fts(nolang")
    end
  end

  describe "parse/2 with filters" do
    test "parses simple equality filter" do
      assert {:ok, result} = Parser.parse(%{"status" => "eq.active"})
      assert [%{field: "status", operator: :eq, value: "active"}] = result.filters
    end

    test "parses multiple filters" do
      assert {:ok, result} =
               Parser.parse(%{"status" => "eq.active", "total" => "gte.100"})

      fields = Enum.map(result.filters, & &1.field) |> Enum.sort()
      assert fields == ["status", "total"]
    end

    test "skips standard params as filters" do
      assert {:ok, result} =
               Parser.parse(%{"status" => "eq.active", "select" => "id,name", "order" => "name"})

      assert length(result.filters) == 1
      assert hd(result.filters).field == "status"
    end

    test "allowed_fields restricts filter fields" do
      assert {:ok, result} =
               Parser.parse(
                 %{"status" => "eq.active", "secret" => "eq.hidden"},
                 allowed_fields: [:status]
               )

      assert length(result.filters) == 1
      assert hd(result.filters).field == "status"
    end

    test "parses NOT prefix" do
      assert {:ok, result} = Parser.parse(%{"not.status" => "eq.deleted"})

      assert [%{logic: :not, condition: %{field: "status", operator: :eq, value: "deleted"}}] =
               result.filters
    end
  end

  describe "parse/2 with logical operators" do
    test "parses OR condition" do
      assert {:ok, result} = Parser.parse(%{"or" => "(age.lt.18,age.gt.65)"})
      assert [%{logic: :or, conditions: conditions}] = result.filters
      assert length(conditions) == 2
      assert Enum.at(conditions, 0) == %{field: "age", operator: :lt, value: "18"}
      assert Enum.at(conditions, 1) == %{field: "age", operator: :gt, value: "65"}
    end

    test "parses AND condition" do
      assert {:ok, result} = Parser.parse(%{"and" => "(status.eq.active,total.gte.100)"})
      assert [%{logic: :and, conditions: conditions}] = result.filters
      assert length(conditions) == 2
    end
  end

  describe "parse/2 with select" do
    test "parses simple field selection" do
      assert {:ok, result} = Parser.parse(%{"select" => "id,name,email"})

      assert result.select == [
               %{type: :field, name: "id"},
               %{type: :field, name: "name"},
               %{type: :field, name: "email"}
             ]
    end

    test "parses embedded resource selection" do
      assert {:ok, result} = Parser.parse(%{"select" => "id,name,posts(id,title)"})

      assert Enum.at(result.select, 2) == %{
               type: :embed,
               name: "posts",
               fields: ["id", "title"],
               inner: false
             }
    end

    test "nil when no select" do
      assert {:ok, result} = Parser.parse(%{"status" => "eq.active"})
      assert result.select == nil
    end

    test "select=* treated as all columns (nil)" do
      assert {:ok, result} = Parser.parse(%{"select" => "*"})
      assert result.select == nil
    end
  end

  describe "parse/2 with order" do
    test "parses order with direction and nulls" do
      assert {:ok, result} = Parser.parse(%{"order" => "created_at.desc.nullslast,name.asc"})

      assert result.order == [
               %{field: "created_at", direction: :desc, nulls: :last},
               %{field: "name", direction: :asc, nulls: nil}
             ]
    end

    test "defaults to ascending" do
      assert {:ok, result} = Parser.parse(%{"order" => "name"})
      assert result.order == [%{field: "name", direction: :asc, nulls: nil}]
    end

    test "nil when no order" do
      assert {:ok, result} = Parser.parse(%{})
      assert result.order == nil
    end
  end

  describe "parse/2 with pagination" do
    test "parses limit and offset" do
      assert {:ok, result} = Parser.parse(%{"limit" => "10", "offset" => "20"})
      assert result.limit == 10
      assert result.offset == 20
    end

    test "nil when no pagination" do
      assert {:ok, result} = Parser.parse(%{})
      assert result.limit == nil
      assert result.offset == nil
    end

    test "rejects negative limit" do
      assert {:error, :invalid_limit} = Parser.parse(%{"limit" => "-5"})
    end

    test "rejects non-numeric limit" do
      assert {:error, :invalid_limit} = Parser.parse(%{"limit" => "abc"})
    end

    test "max_limit clamps provided limit" do
      assert {:ok, result} = Parser.parse(%{"limit" => "5000"}, max_limit: 1000)
      assert result.limit == 1000
    end

    test "max_limit applies as default when no limit provided" do
      assert {:ok, result} = Parser.parse(%{}, max_limit: 500)
      assert result.limit == 500
    end

    test "max_limit nil means no limit enforced" do
      assert {:ok, result} = Parser.parse(%{"limit" => "99999"}, max_limit: nil)
      assert result.limit == 99_999
    end

    test "provided limit below max_limit is kept" do
      assert {:ok, result} = Parser.parse(%{"limit" => "50"}, max_limit: 1000)
      assert result.limit == 50
    end
  end

  describe "parse/2 with custom params" do
    test "separates custom params from standard and filter params" do
      assert {:ok, result} =
               Parser.parse(
                 %{
                   "status" => "eq.active",
                   "select" => "id,name",
                   "search" => "foo"
                 },
                 allowed_fields: [:status]
               )

      assert result.custom_params == %{"search" => "foo"}
    end
  end

  describe "parse/2 with on_conflict" do
    test "extracts on_conflict param" do
      assert {:ok, result} = Parser.parse(%{"on_conflict" => "name"})
      assert result.on_conflict == "name"
    end

    test "on_conflict is nil when not provided" do
      assert {:ok, result} = Parser.parse(%{"status" => "eq.active"})
      assert result.on_conflict == nil
    end

    test "on_conflict is not treated as a filter" do
      assert {:ok, result} = Parser.parse(%{"on_conflict" => "name", "status" => "eq.active"})
      assert length(result.filters) == 1
      assert hd(result.filters).field == "status"
    end
  end

  describe "parse/2 with columns" do
    test "extracts columns param" do
      assert {:ok, result} = Parser.parse(%{"columns" => "name,price,status"})
      assert result.columns == ["name", "price", "status"]
    end

    test "columns is nil when not provided" do
      assert {:ok, result} = Parser.parse(%{})
      assert result.columns == nil
    end

    test "trims whitespace from columns" do
      assert {:ok, result} = Parser.parse(%{"columns" => "name , price , status"})
      assert result.columns == ["name", "price", "status"]
    end

    test "columns is not treated as a filter" do
      assert {:ok, result} = Parser.parse(%{"columns" => "name,price", "status" => "eq.active"})
      assert length(result.filters) == 1
    end
  end
end
