defmodule PgRest.QueryPipelineTest do
  use ExUnit.Case

  alias PgRest.QueryPipeline

  # We can test that the pipeline builds correct queries even without a DB.
  # We'll use a mock repo module that captures the query.

  defmodule MockRepo do
    def all(query) do
      send(self(), {:repo_all, query})
      []
    end

    def insert(changeset) do
      send(self(), {:repo_insert, changeset})
      {:ok, changeset.data}
    end

    def one(query) do
      send(self(), {:repo_one, query})
      nil
    end

    def update(changeset) do
      send(self(), {:repo_update, changeset})
      {:ok, changeset.data}
    end

    def delete(record) do
      send(self(), {:repo_delete, record})
      {:ok, record}
    end

    def transaction(multi) do
      send(self(), {:repo_transaction, multi})

      results =
        multi
        |> Ecto.Multi.to_list()
        |> Enum.reduce(%{}, fn {key, {:insert, changeset, _opts}}, acc ->
          Map.put(acc, key, changeset.data)
        end)

      {:ok, results}
    end

    def update_all(query, updates) do
      send(self(), {:repo_update_all, query, updates})
      {3, nil}
    end

    def delete_all(query) do
      send(self(), {:repo_delete_all, query})
      {2, nil}
    end

    def insert_all(schema, entries, opts) do
      send(self(), {:repo_insert_all, schema, entries, opts})
      {length(entries), nil}
    end
  end

  describe "execute_read/3" do
    test "builds and executes a filtered query" do
      context = %{repo: MockRepo}
      params = %{"status" => "eq.active", "limit" => "10"}

      assert {:ok, []} = QueryPipeline.execute_read(PgRest.Test.Order, params, context)

      assert_received {:repo_all, query}
      assert %Ecto.Query{} = query
    end

    test "applies scope from resource" do
      context = %{repo: MockRepo, tenant_id: 42}
      params = %{}

      assert {:ok, []} = QueryPipeline.execute_read(PgRest.Test.Order, params, context)

      assert_received {:repo_all, query}
      assert %Ecto.Query{} = query
      # The Order resource's scope adds a tenant_id filter
      assert [_ | _] = query.wheres
    end

    test "handles custom params via handle_param" do
      context = %{repo: MockRepo}
      params = %{"search" => "test"}

      # Product doesn't override handle_param, so the custom param is passed through
      # but the default handle_param just returns the query unchanged
      assert {:ok, []} = QueryPipeline.execute_read(PgRest.Test.Product, params, context)
    end

    test "returns error for invalid params" do
      context = %{repo: MockRepo}
      params = %{"limit" => "-5"}

      assert {:error, :invalid_limit} =
               QueryPipeline.execute_read(PgRest.Test.Order, params, context)
    end
  end

  describe "execute_create/3" do
    test "creates a record via changeset" do
      context = %{repo: MockRepo}
      attrs = %{"name" => "Widget", "price" => "9.99"}

      assert {:ok, _record} = QueryPipeline.execute_create(PgRest.Test.Product, attrs, context)
      assert_received {:repo_insert, %Ecto.Changeset{}}
    end
  end

  describe "execute_update/4" do
    test "returns not_found when record doesn't exist" do
      context = %{repo: MockRepo}

      assert {:error, :not_found} =
               QueryPipeline.execute_update(
                 PgRest.Test.Product,
                 1,
                 %{"name" => "Updated"},
                 context
               )
    end
  end

  describe "execute_delete/3" do
    test "returns not_found when record doesn't exist" do
      context = %{repo: MockRepo}

      assert {:error, :not_found} = QueryPipeline.execute_delete(PgRest.Test.Product, 1, context)
    end
  end

  describe "execute_bulk_create/4" do
    test "creates multiple records via Ecto.Multi transaction" do
      context = %{repo: MockRepo}
      attrs_list = [%{"name" => "A"}, %{"name" => "B"}, %{"name" => "C"}]

      assert {:ok, records} =
               QueryPipeline.execute_bulk_create(PgRest.Test.Product, attrs_list, context)

      assert length(records) == 3
      assert_received {:repo_transaction, _multi}
    end

    test "returns records in order" do
      context = %{repo: MockRepo}
      attrs_list = [%{"name" => "First"}, %{"name" => "Second"}]

      assert {:ok, records} =
               QueryPipeline.execute_bulk_create(PgRest.Test.Product, attrs_list, context)

      assert length(records) == 2
    end
  end

  describe "execute_bulk_update/5" do
    test "calls update_all with filters and updates" do
      context = %{repo: MockRepo}
      params = %{"status" => "eq.active"}
      attrs = %{"status" => "completed"}

      assert {:ok, 3} =
               QueryPipeline.execute_bulk_update(
                 PgRest.Test.Order,
                 params,
                 attrs,
                 context
               )

      assert_received {:repo_update_all, _query, [set: updates]}
      assert {:status, "completed"} in updates
    end

    test "filters unknown fields from updates" do
      context = %{repo: MockRepo}
      params = %{"status" => "eq.active"}
      attrs = %{"status" => "completed", "unknown_field" => "value"}

      assert {:ok, 3} =
               QueryPipeline.execute_bulk_update(
                 PgRest.Test.Order,
                 params,
                 attrs,
                 context
               )

      assert_received {:repo_update_all, _query, [set: updates]}
      refute Keyword.has_key?(updates, :unknown_field)
    end

    test "returns error for invalid filter params" do
      context = %{repo: MockRepo}
      params = %{"limit" => "-1"}
      attrs = %{"status" => "completed"}

      assert {:error, :invalid_limit} =
               QueryPipeline.execute_bulk_update(
                 PgRest.Test.Order,
                 params,
                 attrs,
                 context
               )
    end
  end

  describe "execute_bulk_delete/4" do
    test "calls delete_all with filters" do
      context = %{repo: MockRepo}
      params = %{"status" => "eq.deleted"}

      assert {:ok, 2} =
               QueryPipeline.execute_bulk_delete(PgRest.Test.Order, params, context)

      assert_received {:repo_delete_all, _query}
    end

    test "returns error for invalid filter params" do
      context = %{repo: MockRepo}
      params = %{"limit" => "-1"}

      assert {:error, :invalid_limit} =
               QueryPipeline.execute_bulk_delete(PgRest.Test.Order, params, context)
    end
  end

  describe "execute_upsert/4" do
    test "calls insert_all with on_conflict for merge_duplicates" do
      context = %{repo: MockRepo}
      attrs = %{"name" => "Widget", "price" => "9.99"}

      assert {:ok, 1} =
               QueryPipeline.execute_upsert(PgRest.Test.Product, attrs, context,
                 resolution: :merge_duplicates
               )

      assert_received {:repo_insert_all, PgRest.Test.Product, entries, opts}
      assert length(entries) == 1
      assert {:replace, _fields} = opts[:on_conflict]
      assert opts[:conflict_target] == [:id]
    end

    test "calls insert_all with :nothing for ignore_duplicates" do
      context = %{repo: MockRepo}
      attrs = %{"name" => "Widget"}

      assert {:ok, 1} =
               QueryPipeline.execute_upsert(PgRest.Test.Product, attrs, context,
                 resolution: :ignore_duplicates
               )

      assert_received {:repo_insert_all, PgRest.Test.Product, _entries, opts}
      assert opts[:on_conflict] == :nothing
    end

    test "uses custom on_conflict target" do
      context = %{repo: MockRepo}
      attrs = %{"name" => "Widget"}

      assert {:ok, 1} =
               QueryPipeline.execute_upsert(PgRest.Test.Product, attrs, context,
                 resolution: :merge_duplicates,
                 on_conflict: "name"
               )

      assert_received {:repo_insert_all, PgRest.Test.Product, _entries, opts}
      assert opts[:conflict_target] == [:name]
    end

    test "handles list of attrs for bulk upsert" do
      context = %{repo: MockRepo}
      attrs_list = [%{"name" => "A"}, %{"name" => "B"}]

      assert {:ok, 2} =
               QueryPipeline.execute_upsert(PgRest.Test.Product, attrs_list, context,
                 resolution: :merge_duplicates
               )

      assert_received {:repo_insert_all, PgRest.Test.Product, entries, _opts}
      assert length(entries) == 2
    end

    test "with missing_default=true keeps entries as-is" do
      context = %{repo: MockRepo}
      attrs = %{"name" => "Widget"}

      assert {:ok, 1} =
               QueryPipeline.execute_upsert(PgRest.Test.Product, attrs, context,
                 resolution: :merge_duplicates,
                 missing_default: true
               )

      assert_received {:repo_insert_all, PgRest.Test.Product, [entry], _opts}
      # Should only have the fields from the attrs, not all schema fields
      assert Map.has_key?(entry, :name)
      refute Map.has_key?(entry, :price)
    end

    test "with missing_default=false fills missing fields with nil" do
      context = %{repo: MockRepo}
      attrs = %{"name" => "Widget"}

      assert {:ok, 1} =
               QueryPipeline.execute_upsert(PgRest.Test.Product, attrs, context,
                 resolution: :merge_duplicates,
                 missing_default: false
               )

      assert_received {:repo_insert_all, PgRest.Test.Product, [entry], _opts}
      # All schema fields should be present
      assert Map.has_key?(entry, :name)
      assert Map.has_key?(entry, :price)
      assert entry.price == nil
    end
  end

  describe "execute_bulk_create/3 - transaction rollback" do
    defmodule FailingTransactionMockRepo do
      def transaction(multi) do
        changeset =
          multi
          |> Ecto.Multi.to_list()
          |> Enum.at(1)
          |> elem(1)
          |> elem(1)

        {:error, {:insert, 1}, changeset, %{}}
      end
    end

    test "bulk create where second record fails returns error with correct index" do
      context = %{repo: FailingTransactionMockRepo}
      attrs_list = [%{"name" => "Good"}, %{"name" => ""}, %{"name" => "Also Good"}]

      assert {:error, 1, %Ecto.Changeset{}} =
               QueryPipeline.execute_bulk_create(PgRest.Test.Product, attrs_list, context)
    end

    test "changeset in error result has accessible data" do
      context = %{repo: FailingTransactionMockRepo}
      attrs_list = [%{"name" => "Good"}, %{"name" => "Bad"}]

      {:error, idx, changeset} =
        QueryPipeline.execute_bulk_create(PgRest.Test.Product, attrs_list, context)

      assert idx == 1
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "normalize_keys/2" do
    test "converts string keys to atoms for known fields" do
      fields = [:id, :name, :price]

      result = QueryPipeline.normalize_keys(%{"name" => "Widget", "price" => "9.99"}, fields)

      assert result == %{name: "Widget", price: "9.99"}
    end

    test "filters out unknown fields" do
      fields = [:id, :name, :price]

      result =
        QueryPipeline.normalize_keys(
          %{"name" => "Widget", "unknown" => "value"},
          fields
        )

      assert result == %{name: "Widget"}
      refute Map.has_key?(result, :unknown)
    end
  end
end
