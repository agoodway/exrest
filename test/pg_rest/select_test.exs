defmodule PgRest.SelectTest do
  use ExUnit.Case

  alias PgRest.Select

  # --- Embed Field Selection (Task 13) ---

  describe "apply_select/4 - embed field selection" do
    test "nil select returns query unchanged" do
      query = Select.apply_select(PgRest.Test.Author, nil, PgRest.Test.Author, %{})
      assert query == PgRest.Test.Author
    end

    test "simple embed preloads association" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      assert inspect(query) =~ "posts"
    end

    test "embed with specific fields builds preload query with select" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["id", "title"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "posts"
    end

    test "embed with empty fields list uses simple preload" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: [], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
    end

    test "multiple embeds preloads all associations" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "comments", fields: ["*"], inner: false},
        %{type: :embed, name: "tags", fields: ["*"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})
      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "comments"
      assert query_str =~ "tags"
    end
  end

  # --- Embedded Resource Filtering (Task 14) ---

  describe "apply_select/4 - embed filtering via preload queries" do
    test "embed with filters builds filtered preload query" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :eq, value: "published"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "posts"
    end

    test "embed filters with multiple conditions" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["id", "title"], inner: false}
      ]

      embed_filters = %{
        "posts" => [
          %{field: "status", operator: :eq, value: "published"},
          %{field: "title", operator: :like, value: "%Elixir%"}
        ]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
    end

    test "embed filters with in operator" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :in, value: ["published", "draft"]}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
    end

    test "embed without matching filters uses simple preload" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      # Filters for a different embed
      embed_filters = %{
        "comments" => [%{field: "status", operator: :eq, value: "approved"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
    end
  end

  # --- !inner Joins (Task 15) ---

  describe "apply_select/4 - !inner join" do
    test "!inner adds inner join to query" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
      assert hd(query.joins).qual == :inner
    end

    test "!inner with embed filters applies WHERE on join" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :eq, value: "published"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
      assert [_join] = query.joins
      # Should have where clauses from the join filter
      assert [_ | _] = query.wheres
    end

    test "!inner applies distinct to avoid duplicates" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      assert query.distinct == true or query.distinct != nil
    end

    test "non-inner embed does not add join" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      assert query.joins == []
    end

    test "multiple !inner embeds on has_many add multiple joins" do
      select_ast = [
        %{type: :embed, name: "comments", fields: ["*"], inner: true},
        %{type: :embed, name: "author", fields: ["*"], inner: true}
      ]

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 2
    end

    test "!inner on many_to_many raises ArgumentError" do
      select_ast = [
        %{type: :embed, name: "tags", fields: ["*"], inner: true}
      ]

      assert_raise ArgumentError, ~r/!inner join not supported for many_to_many/, fn ->
        Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})
      end
    end
  end

  # --- Anti-Joins (Task 17) ---

  describe "apply_select/4 - anti-joins" do
    test "embed with is_null filter applies left join + where is_nil" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: [], inner: false}
      ]

      embed_filters = %{
        "posts" => [%{field: :__embed_exists__, operator: :is_null, value: true}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
      assert [join] = query.joins
      assert join.qual == :left
      assert [_ | _] = query.wheres
    end

    test "embed with is_null false filter applies inner join (existence check)" do
      select_ast = [
        %{type: :embed, name: "posts", fields: [], inner: false}
      ]

      embed_filters = %{
        "posts" => [%{field: :__embed_exists__, operator: :is_null, value: false}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
      assert hd(query.joins).qual == :inner
    end
  end

  # --- Nested Embeds (Task 16) ---

  describe "apply_select/4 - nested embeds" do
    test "two-level nested embed builds recursive preload" do
      select_ast = [
        %{type: :field, name: "id"},
        %{
          type: :embed,
          name: "posts",
          inner: false,
          fields: [
            "id",
            %{type: :embed, name: "comments", fields: ["body"], inner: false}
          ]
        }
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
    end

    test "nested embed with wildcard at inner level" do
      select_ast = [
        %{
          type: :embed,
          name: "posts",
          inner: false,
          fields: [
            "title",
            %{type: :embed, name: "comments", fields: ["*"], inner: false}
          ]
        }
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
    end

    test "multiple nested embeds at same level" do
      select_ast = [
        %{
          type: :embed,
          name: "posts",
          inner: false,
          fields: [
            "title",
            %{type: :embed, name: "comments", fields: ["body"], inner: false},
            %{type: :embed, name: "tags", fields: ["name"], inner: false}
          ]
        }
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
    end
  end

  # --- Many-to-Many (Task 18) ---

  describe "apply_select/4 - many-to-many associations" do
    test "many_to_many embed preloads through join table" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "tags", fields: ["*"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})
      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "tags"
    end

    test "many_to_many with field selection" do
      select_ast = [
        %{type: :embed, name: "tags", fields: ["name"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})
      assert %Ecto.Query{} = query
    end

    test "many_to_many with filters" do
      select_ast = [
        %{type: :embed, name: "tags", fields: ["*"], inner: false}
      ]

      embed_filters = %{
        "tags" => [%{field: "name", operator: :eq, value: "elixir"}]
      }

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, embed_filters)
      assert %Ecto.Query{} = query
    end
  end

  # --- Root Field Selection ---

  describe "apply_select/4 - root field selection" do
    test "select specific root fields" do
      # Ensure atom exists before test (schema fields may not be loaded yet)
      _ = :first_name

      select_ast = [
        %{type: :field, name: "id"},
        %{type: :field, name: "first_name"}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      assert query.select != nil
    end

    test "fields and embeds together" do
      _ = :first_name

      select_ast = [
        %{type: :field, name: "id"},
        %{type: :field, name: "first_name"},
        %{type: :embed, name: "posts", fields: ["title"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query
      assert query.select != nil
      query_str = inspect(query)
      assert query_str =~ "posts"
    end
  end

  # --- Embed Ordering & Pagination (Phase 1) ---

  describe "apply_select/5 - embed ordering and pagination" do
    test "embed with order builds ordered preload query" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      embed_options = %{"posts" => %{order: [%{field: "title", direction: :desc, nulls: nil}]}}

      query =
        Select.apply_select(
          PgRest.Test.Author,
          select_ast,
          PgRest.Test.Author,
          %{},
          embed_options
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "order_by"
    end

    test "embed with limit builds limited preload query" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      embed_options = %{"posts" => %{limit: 5}}

      query =
        Select.apply_select(
          PgRest.Test.Author,
          select_ast,
          PgRest.Test.Author,
          %{},
          embed_options
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "limit"
    end

    test "embed with order + limit + offset combined" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      embed_options = %{
        "posts" => %{
          order: [%{field: "title", direction: :asc, nulls: nil}],
          limit: 10,
          offset: 5
        }
      }

      query =
        Select.apply_select(
          PgRest.Test.Author,
          select_ast,
          PgRest.Test.Author,
          %{},
          embed_options
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "order_by"
      assert query_str =~ "limit"
      assert query_str =~ "offset"
    end

    test "embed options with no matching embed silently ignored" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      # Options for a different embed than what's in select
      embed_options = %{"comments" => %{limit: 5}}

      query =
        Select.apply_select(
          PgRest.Test.Author,
          select_ast,
          PgRest.Test.Author,
          %{},
          embed_options
        )

      assert %Ecto.Query{} = query
    end

    test "embed with options and filters combined" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :eq, value: "published"}]
      }

      embed_options = %{
        "posts" => %{order: [%{field: "title", direction: :desc, nulls: nil}], limit: 3}
      }

      query =
        Select.apply_select(
          PgRest.Test.Author,
          select_ast,
          PgRest.Test.Author,
          embed_filters,
          embed_options
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "order_by"
      assert query_str =~ "limit"
    end
  end

  # --- Self-Referential Schemas (Phase 2) ---

  describe "apply_select/5 - self-referential schemas" do
    test "embed parent on self-referential schema" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :field, name: "name"},
        %{type: :embed, name: "parent", fields: ["name"], inner: false}
      ]

      query =
        Select.apply_select(PgRest.Test.Category, select_ast, PgRest.Test.Category, %{})

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "parent"
    end

    test "embed children on self-referential schema" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "children", fields: ["*"], inner: false}
      ]

      query =
        Select.apply_select(PgRest.Test.Category, select_ast, PgRest.Test.Category, %{})

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "children"
    end

    test "anti-join on self-referential children (leaf categories)" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "children", fields: [], inner: false}
      ]

      embed_filters = %{
        "children" => [%{field: :__embed_exists__, operator: :is_null, value: true}]
      }

      query =
        Select.apply_select(PgRest.Test.Category, select_ast, PgRest.Test.Category, embed_filters)

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
      assert hd(query.joins).qual == :left
    end

    test "!inner on self-referential children" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "children", fields: ["*"], inner: true}
      ]

      query =
        Select.apply_select(PgRest.Test.Category, select_ast, PgRest.Test.Category, %{})

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
      assert hd(query.joins).qual == :inner
    end
  end

  # --- Multiple FK Disambiguation (Phase 2) ---

  describe "apply_select/5 - multiple FK disambiguation" do
    test "embed billing_address by association name" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "billing_address", fields: ["street", "city"], inner: false}
      ]

      query =
        Select.apply_select(
          PgRest.Test.ShippingOrder,
          select_ast,
          PgRest.Test.ShippingOrder,
          %{}
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "billing_address"
    end

    test "embed shipping_address by association name" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "shipping_address", fields: ["street", "city"], inner: false}
      ]

      query =
        Select.apply_select(
          PgRest.Test.ShippingOrder,
          select_ast,
          PgRest.Test.ShippingOrder,
          %{}
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "shipping_address"
    end

    test "both addresses embedded simultaneously" do
      _ = :street
      _ = :city

      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "billing_address", fields: ["street", "city"], inner: false},
        %{type: :embed, name: "shipping_address", fields: ["street", "city"], inner: false}
      ]

      query =
        Select.apply_select(
          PgRest.Test.ShippingOrder,
          select_ast,
          PgRest.Test.ShippingOrder,
          %{}
        )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "billing_address"
      assert query_str =~ "shipping_address"
    end

    test "!inner on one FK embed" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "billing_address", fields: ["*"], inner: true}
      ]

      query =
        Select.apply_select(
          PgRest.Test.ShippingOrder,
          select_ast,
          PgRest.Test.ShippingOrder,
          %{}
        )

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
      assert hd(query.joins).qual == :inner
    end

    test "filters on one FK embed" do
      select_ast = [
        %{type: :embed, name: "billing_address", fields: ["*"], inner: false}
      ]

      embed_filters = %{
        "billing_address" => [%{field: "city", operator: :eq, value: "NYC"}]
      }

      query =
        Select.apply_select(
          PgRest.Test.ShippingOrder,
          select_ast,
          PgRest.Test.ShippingOrder,
          embed_filters
        )

      assert %Ecto.Query{} = query
    end
  end

  # --- Nested Embed Filters (Phase 3) ---

  describe "apply_select/5 - nested embed filters" do
    test "two-level nested filter applies to nested preload sub-query" do
      select_ast = [
        %{type: :field, name: "id"},
        %{
          type: :embed,
          name: "posts",
          inner: false,
          fields: [
            "id",
            %{type: :embed, name: "comments", fields: ["body"], inner: false}
          ]
        }
      ]

      embed_filters = %{
        "posts.comments" => [%{field: "status", operator: :eq, value: "approved"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
    end

    test "filter at first AND second level simultaneously" do
      select_ast = [
        %{
          type: :embed,
          name: "posts",
          inner: false,
          fields: [
            "id",
            %{type: :embed, name: "comments", fields: ["body"], inner: false}
          ]
        }
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :eq, value: "published"}],
        "posts.comments" => [%{field: "status", operator: :eq, value: "approved"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
    end

    test "nested filter with no matching nested embed is silently ignored" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: false}
      ]

      # Filter for a nested embed that doesn't exist in the select tree
      embed_filters = %{
        "posts.comments" => [%{field: "status", operator: :eq, value: "approved"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert %Ecto.Query{} = query
    end
  end

  # --- Error Handling (Phase 4) ---

  describe "apply_select/5 - error handling" do
    test "unknown embed with field selection raises ArgumentError with useful message" do
      # Field selection forces build_preload_query path which calls get_related_module
      select_ast = [
        %{type: :embed, name: "nonexistent", fields: ["id", "name"], inner: false}
      ]

      assert_raise ArgumentError, ~r/unknown association/, fn ->
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      end
    end

    test "error message includes available associations" do
      select_ast = [
        %{type: :embed, name: "nonexistent", fields: ["id"], inner: false}
      ]

      error =
        assert_raise ArgumentError, fn ->
          Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
        end

      assert error.message =~ "Available:"
      assert error.message =~ "posts"
    end

    test "unknown embed with filters raises ArgumentError" do
      select_ast = [
        %{type: :embed, name: "nonexistent", fields: ["*"], inner: false}
      ]

      embed_filters = %{
        "nonexistent" => [%{field: "status", operator: :eq, value: "active"}]
      }

      assert_raise ArgumentError, ~r/unknown association/, fn ->
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)
      end
    end
  end

  # --- PK/FK Auto-Inclusion in Field Selects (Bug 1 Regression) ---

  describe "apply_select/4 - PK/FK auto-inclusion" do
    test "root PK auto-included when selecting fields with has_many embed" do
      _ = :first_name
      _ = :last_name

      select_ast = [
        %{type: :field, name: "first_name"},
        %{type: :field, name: "last_name"},
        %{type: :embed, name: "posts", fields: ["title"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})
      assert %Ecto.Query{} = query

      selected = root_select_fields(query)
      assert :id in selected
      assert :first_name in selected
      assert :last_name in selected
    end

    test "root PK and FK auto-included when selecting fields with belongs_to embed" do
      _ = :title
      _ = :body

      select_ast = [
        %{type: :field, name: "title"},
        %{type: :field, name: "body"},
        %{type: :embed, name: "author", fields: ["first_name"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})
      assert %Ecto.Query{} = query

      selected = root_select_fields(query)
      assert :id in selected
      assert :author_id in selected
      assert :title in selected
      assert :body in selected
    end

    test "preload sub-query includes FK for has_many" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "posts", fields: ["title"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})

      sub_query = get_preload_sub_query(query, :posts)
      assert sub_query != nil

      sub_selected = root_select_fields(sub_query)
      assert :author_id in sub_selected
      assert :id in sub_selected
    end

    test "preload sub-query includes PK for belongs_to" do
      select_ast = [
        %{type: :field, name: "id"},
        %{type: :embed, name: "author", fields: ["first_name"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Post, select_ast, PgRest.Test.Post, %{})

      sub_query = get_preload_sub_query(query, :author)
      assert sub_query != nil

      sub_selected = root_select_fields(sub_query)
      assert :id in sub_selected
    end

    test "no duplicate fields when user already selects PK" do
      _ = :first_name

      select_ast = [
        %{type: :field, name: "id"},
        %{type: :field, name: "first_name"},
        %{type: :embed, name: "posts", fields: ["title"], inner: false}
      ]

      query = Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, %{})

      selected = root_select_fields(query)
      id_count = Enum.count(selected, &(&1 == :id))
      assert id_count == 1
    end

    test "multiple embeds collect all required FKs" do
      _ = :reference

      select_ast = [
        %{type: :field, name: "reference"},
        %{type: :embed, name: "billing_address", fields: ["street"], inner: false},
        %{type: :embed, name: "shipping_address", fields: ["city"], inner: false}
      ]

      query =
        Select.apply_select(
          PgRest.Test.ShippingOrder,
          select_ast,
          PgRest.Test.ShippingOrder,
          %{}
        )

      selected = root_select_fields(query)
      assert :id in selected
      assert :billing_address_id in selected
      assert :shipping_address_id in selected
    end
  end

  # --- Join Filter Named Binding (Bug 2 Regression) ---

  describe "apply_select/4 - join filter targets correct table binding" do
    test "eq filter on inner join targets the joined table, not root" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :eq, value: "published"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert [_ | _] = query.wheres
      binding_indices = where_field_binding_indices(query)
      assert 1 in binding_indices
      refute 0 in binding_indices
    end

    test "neq filter on inner join targets joined table" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :neq, value: "draft"}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert [_ | _] = query.wheres
      binding_indices = where_field_binding_indices(query)
      assert 1 in binding_indices
      refute 0 in binding_indices
    end

    test "gt/gte/lt/lte filters on inner join target joined table" do
      for {op, val} <- [{:gt, "5"}, {:gte, "5"}, {:lt, "100"}, {:lte, "100"}] do
        select_ast = [
          %{type: :embed, name: "posts", fields: ["*"], inner: true}
        ]

        embed_filters = %{
          "posts" => [%{field: "id", operator: op, value: val}]
        }

        query =
          Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

        assert [_ | _] = query.wheres, "expected wheres for #{op}"
        binding_indices = where_field_binding_indices(query)
        assert 1 in binding_indices, "expected join binding for #{op}"
        refute 0 in binding_indices, "should not target root for #{op}"
      end
    end

    test "like/ilike filters on inner join target joined table" do
      for op <- [:like, :ilike] do
        select_ast = [
          %{type: :embed, name: "posts", fields: ["*"], inner: true}
        ]

        embed_filters = %{
          "posts" => [%{field: "title", operator: op, value: "%test%"}]
        }

        query =
          Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

        assert [_ | _] = query.wheres
        binding_indices = where_field_binding_indices(query)
        assert 1 in binding_indices
        refute 0 in binding_indices
      end
    end

    test "in filter on inner join targets joined table" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      embed_filters = %{
        "posts" => [%{field: "status", operator: :in, value: ["draft", "published"]}]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert [_ | _] = query.wheres
      binding_indices = where_field_binding_indices(query)
      assert 1 in binding_indices
      refute 0 in binding_indices
    end

    test "is_null true/false filters on inner join target joined table" do
      for val <- [true, false] do
        select_ast = [
          %{type: :embed, name: "posts", fields: ["*"], inner: true}
        ]

        embed_filters = %{
          "posts" => [%{field: "status", operator: :is_null, value: val}]
        }

        query =
          Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

        assert [_ | _] = query.wheres
        binding_indices = where_field_binding_indices(query)
        assert 1 in binding_indices
        refute 0 in binding_indices
      end
    end

    test "multiple filters on same join all target joined table" do
      select_ast = [
        %{type: :embed, name: "posts", fields: ["*"], inner: true}
      ]

      embed_filters = %{
        "posts" => [
          %{field: "status", operator: :eq, value: "published"},
          %{field: "id", operator: :gt, value: "5"}
        ]
      }

      query =
        Select.apply_select(PgRest.Test.Author, select_ast, PgRest.Test.Author, embed_filters)

      assert length(query.wheres) == 2

      Enum.each(query.wheres, fn where_clause ->
        indices = extract_field_bindings(where_clause.expr)
        assert 1 in indices
        refute 0 in indices
      end)
    end
  end

  # --- Helpers ---

  defp root_select_fields(query) do
    case query.select do
      %{take: %{0 => {_, fields}}} -> fields
      _ -> []
    end
  end

  defp get_preload_sub_query(query, assoc_name) do
    query.preloads
    |> List.flatten()
    |> Enum.find_value(fn
      {^assoc_name, %Ecto.Query{} = sub} -> sub
      _ -> nil
    end)
  end

  defp where_field_binding_indices(query) do
    query.wheres
    |> Enum.flat_map(fn %{expr: expr} ->
      extract_field_bindings(expr)
    end)
    |> Enum.uniq()
  end

  defp extract_field_bindings({{:., _, [{:&, _, [idx]}, _field]}, _, _}), do: [idx]

  defp extract_field_bindings(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.flat_map(&extract_field_bindings/1)
  end

  defp extract_field_bindings(list) when is_list(list) do
    Enum.flat_map(list, &extract_field_bindings/1)
  end

  defp extract_field_bindings(_), do: []
end
