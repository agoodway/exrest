defmodule PgRest.QueryPipeline do
  @moduledoc """
  Composes query execution through a pipeline:
  base_query -> scope -> URL filters -> handle_param -> select -> order -> paginate -> execute -> after_load
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias PgRest.{Filter, Order, Parser, Select, TypeCaster}

  @doc """
  Executes a read (GET) pipeline: parse params, apply scope/filters/select/order/pagination, fetch records.

  Returns `{:ok, records}` or `{:ok, records, range_info}` when count mode is requested.
  """
  @spec execute_read(module(), map(), map(), keyword()) ::
          {:ok, [map()]} | {:ok, [map()], map()} | {:error, term()}
  def execute_read(resource_module, params, context, pipeline_opts \\ []) when is_map(params) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :read, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      config = resource_module.__pgrest_config__()
      max_limit = Keyword.get(pipeline_opts, :max_limit)
      prefer = Keyword.get(pipeline_opts, :prefer, %{})

      result =
        with {:ok, parsed} <-
               Parser.parse(params, allowed_fields: config.fields, max_limit: max_limit),
             {:ok, cast_filters} <- TypeCaster.cast_filters(parsed.filters, resource_module) do
          embed_filters = Map.get(parsed, :embed_filters, %{})
          embed_options = Map.get(parsed, :embed_options, %{})

          base_query =
            resource_module
            |> resource_module.scope(context)
            |> apply_custom_params(resource_module, parsed.custom_params, context)
            |> Filter.apply_all(cast_filters)
            |> Select.apply_select(parsed.select, resource_module, embed_filters, embed_options)
            |> Order.apply_order(parsed.order)

          paginated_query = apply_pagination(base_query, parsed.limit, parsed.offset)

          records =
            repo.all(paginated_query)
            |> Enum.map(&resource_module.after_load(&1, context))

          count_mode = Map.get(prefer, :count)
          build_response(records, count_mode, parsed.offset, base_query, repo, max_limit)
        end

      {result, meta}
    end)
  end

  @doc """
  Executes a create (POST) pipeline: build changeset, insert, apply after_load.
  """
  @spec execute_create(module(), map(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def execute_create(resource_module, attrs, context) when is_map(attrs) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :create, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      struct = struct(resource_module)
      changeset = resource_module.changeset(struct, attrs, context)

      result =
        case repo.insert(changeset) do
          {:ok, record} ->
            {:ok, resource_module.after_load(record, context)}

          {:error, changeset} ->
            {:error, changeset}
        end

      {result, meta}
    end)
  end

  @doc """
  Executes an update (PATCH) pipeline: find by PK within scope, apply changeset, update.
  """
  @spec execute_update(module(), term(), map(), map()) ::
          {:ok, map()} | {:error, :not_found | Ecto.Changeset.t()}
  def execute_update(resource_module, id, attrs, context) when is_map(attrs) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :update, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      result = do_update(resource_module, id, attrs, context, repo)
      {result, meta}
    end)
  end

  defp do_update(resource_module, id, attrs, context, repo) do
    config = resource_module.__pgrest_config__()
    [pk_field] = config.primary_key

    query =
      resource_module
      |> resource_module.scope(context)
      |> where([r], field(r, ^pk_field) == ^id)

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      record ->
        changeset = resource_module.changeset(record, attrs, context)

        case repo.update(changeset) do
          {:ok, updated} ->
            {:ok, resource_module.after_load(updated, context)}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Executes a delete (DELETE) pipeline: find by PK within scope, delete.
  """
  @spec execute_delete(module(), term(), map()) ::
          {:ok, map()} | {:error, :not_found | Ecto.Changeset.t()}
  def execute_delete(resource_module, id, context) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :delete, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      result = do_delete(resource_module, id, context, repo)
      {result, meta}
    end)
  end

  defp do_delete(resource_module, id, context, repo) do
    config = resource_module.__pgrest_config__()
    [pk_field] = config.primary_key

    query =
      resource_module
      |> resource_module.scope(context)
      |> where([r], field(r, ^pk_field) == ^id)

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      record ->
        case repo.delete(record) do
          {:ok, deleted} -> {:ok, deleted}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Bulk insert multiple records using Ecto.Multi for individual changeset validation.
  Returns {:ok, records} or {:error, index, changeset}.
  """
  @spec execute_bulk_create(module(), [map()], map(), keyword()) ::
          {:ok, [map()]} | {:error, non_neg_integer(), Ecto.Changeset.t()}
  def execute_bulk_create(resource_module, attrs_list, context, _opts \\ [])
      when is_list(attrs_list) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :bulk_create, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      result = do_bulk_create(resource_module, attrs_list, context, repo)
      {result, meta}
    end)
  end

  defp do_bulk_create(resource_module, attrs_list, context, repo) do
    multi =
      attrs_list
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {attrs, idx}, multi ->
        changeset = resource_module.changeset(struct(resource_module), attrs, context)
        Ecto.Multi.insert(multi, {:insert, idx}, changeset)
      end)

    case repo.transaction(multi) do
      {:ok, results} ->
        records =
          results
          |> Enum.sort_by(fn {{:insert, idx}, _} -> idx end)
          |> Enum.map(fn {_, record} -> resource_module.after_load(record, context) end)

        {:ok, records}

      {:error, {:insert, idx}, changeset, _changes} ->
        {:error, idx, changeset}
    end
  end

  @doc """
  Bulk update records matching query filters.
  Returns {:ok, count} or {:ok, count, records} when returning.
  """
  @spec execute_bulk_update(module(), map(), map(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:ok, non_neg_integer(), [map()]} | {:error, term()}
  def execute_bulk_update(resource_module, params, attrs, context, opts \\ []) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :bulk_update, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      config = resource_module.__pgrest_config__()
      return_records? = Keyword.get(opts, :return, false)

      result =
        with {:ok, parsed} <- Parser.parse(params, allowed_fields: config.fields),
             {:ok, cast_filters} <- TypeCaster.cast_filters(parsed.filters, resource_module) do
          query =
            resource_module
            |> resource_module.scope(context)
            |> Filter.apply_all(cast_filters)

          updates = normalize_updates(attrs, config.fields)
          run_update_all(repo, query, updates, return_records?, resource_module, context)
        end

      {result, meta}
    end)
  end

  defp run_update_all(repo, query, updates, true, resource_module, context) do
    query_with_select = select(query, [r], r)

    case repo.update_all(query_with_select, set: updates) do
      {count, records} when is_list(records) ->
        records = Enum.map(records, &resource_module.after_load(&1, context))
        {:ok, count, records}

      {count, nil} ->
        {:ok, count, []}
    end
  end

  defp run_update_all(repo, query, updates, false, _resource_module, _context) do
    {count, _} = repo.update_all(query, set: updates)
    {:ok, count}
  end

  @doc """
  Bulk delete records matching query filters.
  Returns {:ok, count} or {:ok, count, records} when returning.
  """
  @spec execute_bulk_delete(module(), map(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:ok, non_neg_integer(), [map()]} | {:error, term()}
  def execute_bulk_delete(resource_module, params, context, opts \\ []) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :bulk_delete, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      config = resource_module.__pgrest_config__()
      return_records? = Keyword.get(opts, :return, false)

      result =
        with {:ok, parsed} <- Parser.parse(params, allowed_fields: config.fields),
             {:ok, cast_filters} <- TypeCaster.cast_filters(parsed.filters, resource_module) do
          query =
            resource_module
            |> resource_module.scope(context)
            |> Filter.apply_all(cast_filters)

          run_delete_all(repo, query, return_records?, resource_module, context)
        end

      {result, meta}
    end)
  end

  defp run_delete_all(repo, query, true, resource_module, context) do
    query_with_select = select(query, [r], r)

    case repo.delete_all(query_with_select) do
      {count, records} when is_list(records) ->
        records = Enum.map(records, &resource_module.after_load(&1, context))
        {:ok, count, records}

      {count, nil} ->
        {:ok, count, []}
    end
  end

  defp run_delete_all(repo, query, false, _resource_module, _context) do
    {count, _} = repo.delete_all(query)
    {:ok, count}
  end

  @doc """
  Upsert records using Ecto's on_conflict support.
  Returns {:ok, count} or {:ok, count, records} when returning.
  """
  @spec execute_upsert(module(), map() | [map()], map(), keyword()) ::
          {:ok, non_neg_integer()} | {:ok, non_neg_integer(), [map()]} | {:error, term()}
  def execute_upsert(resource_module, attrs_list, context, opts \\ []) do
    repo = Map.fetch!(context, :repo)
    meta = %{resource: resource_module, operation: :upsert, repo: repo}

    :telemetry.span([:pg_rest, :query], meta, fn ->
      config = resource_module.__pgrest_config__()
      return_records? = Keyword.get(opts, :return, false)
      resolution = Keyword.get(opts, :resolution, :merge_duplicates)
      on_conflict_param = Keyword.get(opts, :on_conflict)
      missing_default? = Keyword.get(opts, :missing_default, false)

      attrs_list = if is_map(attrs_list), do: [attrs_list], else: attrs_list

      on_conflict = build_on_conflict(resolution, config)
      conflict_target = build_conflict_target(on_conflict_param, config)

      entries =
        attrs_list
        |> Enum.map(&normalize_keys(&1, config.fields))
        |> maybe_apply_missing_default(missing_default?, config.fields)

      insert_opts =
        [on_conflict: on_conflict, conflict_target: conflict_target]
        |> maybe_add_returning(return_records?)

      result =
        try do
          {count, records} = repo.insert_all(resource_module, entries, insert_opts)

          if return_records? do
            records = (records || []) |> Enum.map(&resource_module.after_load(&1, context))
            {:ok, count, records}
          else
            {:ok, count}
          end
        rescue
          e in [Ecto.ConstraintError, Postgrex.Error] ->
            {:error, Exception.message(e)}
        end

      {result, meta}
    end)
  end

  @doc """
  Converts string-keyed JSON attrs to atom-keyed maps, filtering to known schema fields.
  """
  @spec normalize_keys(map(), [atom()]) :: map()
  def normalize_keys(attrs, fields) when is_map(attrs) do
    field_strings = Enum.map(fields, &Atom.to_string/1)

    attrs
    |> Enum.filter(fn {k, _v} -> k in field_strings end)
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.new()
  end

  defp build_response(records, nil, _offset, _base_query, _repo, _max_limit) do
    {:ok, records}
  end

  defp build_response(records, count_mode, offset, base_query, repo, max_limit) do
    page_count = length(records)
    offset = offset || 0
    total = get_total_count(repo, base_query, count_mode, page_count, max_limit)

    range_info = %{
      offset: offset,
      count: page_count,
      total: total
    }

    {:ok, records, range_info}
  end

  defp apply_custom_params(query, resource_module, custom_params, context) do
    Enum.reduce(custom_params, query, fn {key, value}, acc ->
      resource_module.handle_param(key, value, acc, context)
    end)
  end

  defp apply_pagination(query, nil, nil), do: query

  defp apply_pagination(query, limit, nil) when is_integer(limit) do
    limit(query, ^limit)
  end

  defp apply_pagination(query, nil, offset) when is_integer(offset) do
    offset(query, ^offset)
  end

  defp apply_pagination(query, limit, offset) when is_integer(limit) and is_integer(offset) do
    query
    |> limit(^limit)
    |> offset(^offset)
  end

  # PostgREST count modes:
  # - exact: Always runs COUNT(*)
  # - planned: Uses EXPLAIN to get planner row estimate
  # - estimated: Hybrid — exact if page_count < max_limit, otherwise max(page_count, planned)
  defp get_total_count(repo, query, :exact, _page_count, _max_limit) do
    count_query = exclude(query, :order_by) |> exclude(:select)
    repo.aggregate(count_query, :count)
  end

  defp get_total_count(repo, query, :planned, _page_count, _max_limit) do
    get_planned_count(repo, query)
  end

  # PostgREST estimated logic: if results fill the page, use planned estimate.
  # Otherwise use exact count (results fit within max_limit).
  defp get_total_count(repo, query, :estimated, page_count, max_limit)
       when is_integer(max_limit) and page_count >= max_limit do
    planned = get_planned_count(repo, query)
    max(page_count, planned)
  end

  defp get_total_count(repo, query, :estimated, _page_count, _max_limit) do
    count_query = exclude(query, :order_by) |> exclude(:select)
    repo.aggregate(count_query, :count)
  end

  defp get_planned_count(repo, query) do
    # PostgREST uses EXPLAIN (FORMAT JSON) and extracts "Plan Rows"
    count_query = exclude(query, :order_by) |> exclude(:select)

    try do
      {sql, params} = SQL.to_sql(:all, repo, count_query)
      explain_sql = "EXPLAIN (FORMAT JSON) #{sql}"

      case repo.query(explain_sql, params) do
        {:ok, %{rows: [[json]]}} when is_list(json) ->
          extract_plan_rows(json, repo, count_query)

        _ ->
          fallback_exact_count(repo, count_query)
      end
    rescue
      _ -> fallback_exact_count(repo, count_query)
    end
  end

  defp extract_plan_rows(json, repo, count_query) do
    case json |> List.first() |> get_in(["Plan", "Plan Rows"]) do
      rows when is_number(rows) -> trunc(rows)
      _ -> fallback_exact_count(repo, count_query)
    end
  end

  defp fallback_exact_count(repo, count_query) do
    repo.aggregate(count_query, :count)
  end

  defp normalize_updates(attrs, fields) when is_map(attrs) do
    field_strings = Enum.map(fields, &Atom.to_string/1)

    attrs
    |> Enum.filter(fn {k, _v} -> k in field_strings end)
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp build_on_conflict(:merge_duplicates, config) do
    # Replace all non-PK fields
    pk_fields = config.primary_key
    replace_fields = config.fields -- pk_fields
    {:replace, replace_fields}
  end

  defp build_on_conflict(:ignore_duplicates, _config) do
    :nothing
  end

  defp build_conflict_target(nil, config) do
    config.primary_key
  end

  defp build_conflict_target(column_string, _config) when is_binary(column_string) do
    column_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp maybe_apply_missing_default(entries, true, _fields), do: entries

  defp maybe_apply_missing_default(entries, false, fields) do
    # Without missing=default, explicitly set missing schema fields to nil
    Enum.map(entries, fn entry ->
      Enum.reduce(fields, entry, fn field, acc ->
        Map.put_new(acc, field, nil)
      end)
    end)
  end

  defp maybe_add_returning(opts, true), do: Keyword.put(opts, :returning, true)
  defp maybe_add_returning(opts, false), do: opts
end
