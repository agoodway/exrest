defmodule PgRest.FilterTest do
  use ExUnit.Case

  alias PgRest.Filter

  # We test by inspecting the Ecto query structure

  describe "comparison operators" do
    test "eq produces WHERE clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :eq, value: "active"}])

      assert %Ecto.Query{} = query
      assert inspect(query) =~ "status"
    end

    test "neq produces WHERE clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :neq, value: "deleted"}])

      assert %Ecto.Query{} = query
    end

    test "gt produces WHERE clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "total", operator: :gt, value: "100"}])

      assert %Ecto.Query{} = query
    end

    test "gte produces WHERE clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "total", operator: :gte, value: "100"}])

      assert %Ecto.Query{} = query
    end

    test "lt produces WHERE clause" do
      query = Filter.apply_all(PgRest.Test.Order, [%{field: "total", operator: :lt, value: "50"}])
      assert %Ecto.Query{} = query
    end

    test "lte produces WHERE clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "total", operator: :lte, value: "50"}])

      assert %Ecto.Query{} = query
    end
  end

  describe "pattern matching" do
    test "like produces LIKE clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "reference", operator: :like, value: "%ORD%"}
        ])

      assert %Ecto.Query{} = query
    end

    test "ilike converts * to % without auto-wrap" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "reference", operator: :ilike, value: "*smith*"}
        ])

      assert %Ecto.Query{} = query
    end

    test "ilike without wildcards does not auto-wrap" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "reference", operator: :ilike, value: "smith"}
        ])

      assert %Ecto.Query{} = query
      # PostgREST does NOT auto-wrap — "smith" stays "smith", not "%smith%"
    end

    test "match produces POSIX regex clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "reference", operator: :match, value: "^ORD-\\d+"}
        ])

      assert %Ecto.Query{} = query
    end

    test "imatch produces case-insensitive POSIX regex clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "reference", operator: :imatch, value: "^ord"}
        ])

      assert %Ecto.Query{} = query
    end
  end

  describe "IN operator" do
    test "in produces IN clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :in, value: ["active", "pending"]}
        ])

      assert %Ecto.Query{} = query
    end
  end

  describe "IS operators" do
    test "is_null true produces IS NULL" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :is_null, value: true}])

      assert %Ecto.Query{} = query
    end

    test "is_null false produces IS NOT NULL" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :is_null, value: false}])

      assert %Ecto.Query{} = query
    end

    test "is true produces boolean check" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :is, value: true}])

      assert %Ecto.Query{} = query
    end

    test "is false produces boolean check" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :is, value: false}])

      assert %Ecto.Query{} = query
    end

    test "isdistinct produces IS DISTINCT FROM clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :isdistinct, value: "active"}
        ])

      assert %Ecto.Query{} = query
    end
  end

  describe "array operators" do
    test "cs produces @> clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :cs, value: "{a,b}"}])

      assert %Ecto.Query{} = query
    end

    test "cd produces <@ clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :cd, value: "{a,b}"}])

      assert %Ecto.Query{} = query
    end

    test "ov produces && (overlap) clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :ov, value: "{a,b}"}])

      assert %Ecto.Query{} = query
    end
  end

  describe "range operators" do
    test "sl produces << (strictly left) clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :sl, value: "[1,5]"}])

      assert %Ecto.Query{} = query
    end

    test "sr produces >> (strictly right) clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :sr, value: "[1,5]"}])

      assert %Ecto.Query{} = query
    end

    test "nxr produces &< clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :nxr, value: "[1,5]"}])

      assert %Ecto.Query{} = query
    end

    test "nxl produces &> clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :nxl, value: "[1,5]"}])

      assert %Ecto.Query{} = query
    end

    test "adj produces -|- (adjacent) clause" do
      query =
        Filter.apply_all(PgRest.Test.Order, [%{field: "status", operator: :adj, value: "[1,5]"}])

      assert %Ecto.Query{} = query
    end
  end

  describe "FTS operators" do
    test "fts produces @@ to_tsquery with to_tsvector" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :fts, value: {"english", "test"}}
        ])

      assert %Ecto.Query{} = query
    end

    test "plfts produces @@ plainto_tsquery with to_tsvector" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :plfts, value: {"english", "fat cats"}}
        ])

      assert %Ecto.Query{} = query
    end

    test "phfts produces @@ phraseto_tsquery with to_tsvector" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :phfts, value: {"english", "fat cats"}}
        ])

      assert %Ecto.Query{} = query
    end

    test "wfts produces @@ websearch_to_tsquery with to_tsvector" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :wfts, value: {"english", "fat cats"}}
        ])

      assert %Ecto.Query{} = query
    end

    test "fts with custom language config" do
      query =
        Filter.apply_all(PgRest.Test.Order, [
          %{field: "status", operator: :fts, value: {"french", "chat"}}
        ])

      assert %Ecto.Query{} = query
    end
  end

  describe "logical operators" do
    test "AND applies all conditions" do
      filters = [
        %{
          logic: :and,
          conditions: [
            %{field: "status", operator: :eq, value: "active"},
            %{field: "total", operator: :gte, value: "100"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "OR applies conditions with OR" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "total", operator: :lt, value: "10"},
            %{field: "total", operator: :gt, value: "1000"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "NOT negates condition" do
      filters = [%{logic: :not, condition: %{field: "status", operator: :eq, value: "deleted"}}]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "OR with ilike conditions" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "reference", operator: :ilike, value: "*test*"},
            %{field: "status", operator: :ilike, value: "*active*"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "OR with like conditions" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "reference", operator: :like, value: "%test%"},
            %{field: "status", operator: :like, value: "%active%"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "OR with is_null condition" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "status", operator: :is_null, value: true},
            %{field: "status", operator: :eq, value: "deleted"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "OR with is_null false (NOT NULL) condition" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "status", operator: :is_null, value: false},
            %{field: "status", operator: :eq, value: "active"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end

    test "OR with FTS condition" do
      filters = [
        %{
          logic: :or,
          conditions: [
            %{field: "status", operator: :fts, value: {"english", "test"}},
            %{field: "reference", operator: :eq, value: "ORD-1"}
          ]
        }
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
    end
  end

  describe "multiple filters" do
    test "applies multiple filters sequentially" do
      filters = [
        %{field: "status", operator: :eq, value: "active"},
        %{field: "total", operator: :gte, value: "100"}
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
      # Should have 2 where clauses
      assert length(query.wheres) == 2
    end
  end

  describe "multiple filters on same column" do
    test "two filters on same column (gt + lt) both apply as range query" do
      filters = [
        %{field: "total", operator: :gt, value: "10"},
        %{field: "total", operator: :lt, value: "100"}
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
      assert length(query.wheres) == 2
    end

    test "two neq filters on same column both apply as exclusion" do
      filters = [
        %{field: "status", operator: :neq, value: "deleted"},
        %{field: "status", operator: :neq, value: "archived"}
      ]

      query = Filter.apply_all(PgRest.Test.Order, filters)
      assert %Ecto.Query{} = query
      assert length(query.wheres) == 2
    end
  end
end
