defmodule PgRest.Plug do
  @moduledoc """
  Phoenix Plug that routes requests to PgRest resources.

  ## Usage

      # In your router:
      forward "/api", PgRest.Plug, repo: MyApp.Repo

  ## Options

  - `:repo` (required) - The Ecto repo module
  - `:json` - JSON encoder/decoder module (default: `Jason`)
  - `:max_limit` - Maximum rows per request, like PostgREST's `db-max-rows` (default: `nil` = no limit)
  - `:context_builder` - A 2-arity function `(conn, opts) -> context_map` for custom context building
  """

  @behaviour Plug

  alias PgRest.{Parser.Select, QueryPipeline, Registry}

  @doc """
  Initializes plug options.

  Requires `:repo`. Optional: `:json` (default `Jason`), `:max_limit`,
  `:context_builder`, `:authorization`.
  """
  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      repo: Keyword.fetch!(opts, :repo),
      json: Keyword.get(opts, :json, Jason),
      max_limit: Keyword.get(opts, :max_limit),
      context_builder: Keyword.get(opts, :context_builder),
      authorization: Keyword.get(opts, :authorization)
    }
  end

  @doc """
  Routes incoming requests to the appropriate resource handler.

  Matches `/:resource` and `/:resource/:id` paths, resolving the resource
  via `PgRest.Registry` and dispatching to the correct CRUD operation.
  """
  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    case conn.path_info do
      [resource_name] ->
        handle_resource(conn, opts, resource_name, nil)

      [resource_name, id] ->
        handle_resource(conn, opts, resource_name, id)

      _ ->
        send_error(conn, opts, 404, "Not found")
    end
  end

  defp handle_resource(conn, opts, resource_name, id) do
    case Registry.get_resource(resource_name) do
      {:ok, config} ->
        dispatch_or_reject(conn, opts, config, id)

      {:error, :not_found} ->
        send_error(conn, opts, 404, "Resource not found")
    end
  end

  defp dispatch_or_reject(conn, opts, config, id) do
    resource_module = config.module
    operation = method_to_operation(conn.method)

    cond do
      is_nil(operation) ->
        send_error(conn, opts, 405, "Method not allowed")

      not operation_allowed?(config, operation) ->
        send_error(conn, opts, 405, "Method not allowed")

      true ->
        authorize_and_dispatch(conn, opts, resource_module, operation, id)
    end
  end

  defp authorize_and_dispatch(conn, opts, resource_module, operation, id) do
    context = build_context(conn, opts)

    case check_authorization(opts.authorization, conn, resource_module, operation, context) do
      :ok ->
        dispatch(conn, opts, resource_module, operation, id, context)

      {:error, reason} ->
        send_error(conn, opts, 403, reason)
    end
  end

  defp method_to_operation("GET"), do: :read
  defp method_to_operation("POST"), do: :create
  defp method_to_operation("PATCH"), do: :update
  defp method_to_operation("DELETE"), do: :delete
  defp method_to_operation(_), do: nil

  defp operation_allowed?(%{allow: :all}, _operation), do: true
  defp operation_allowed?(%{allow: ops}, operation) when is_list(ops), do: operation in ops
  defp operation_allowed?(_config, _operation), do: true

  defp check_authorization(nil, _conn, _resource_module, _operation, _context), do: :ok

  defp check_authorization(auth_module, conn, resource_module, operation, context) do
    auth_module.authorize(conn, resource_module, operation, context)
  end

  defp dispatch(conn, opts, resource_module, :read, nil, context),
    do: handle_list(conn, opts, resource_module, context)

  defp dispatch(conn, opts, resource_module, :read, id, context),
    do: handle_show(conn, opts, resource_module, id, context)

  defp dispatch(conn, opts, resource_module, :create, _id, context),
    do: handle_create(conn, opts, resource_module, context)

  defp dispatch(conn, opts, resource_module, :update, nil, context),
    do: handle_bulk_update(conn, opts, resource_module, context)

  defp dispatch(conn, opts, resource_module, :update, id, context),
    do: handle_update(conn, opts, resource_module, id, context)

  defp dispatch(conn, opts, resource_module, :delete, nil, context),
    do: handle_bulk_delete(conn, opts, resource_module, context)

  defp dispatch(conn, opts, resource_module, :delete, id, context),
    do: handle_delete(conn, opts, resource_module, id, context)

  defp handle_list(conn, opts, resource_module, context) do
    params = conn.query_params
    pipeline_opts = build_pipeline_opts(conn, opts)
    prefer = Keyword.get(pipeline_opts, :prefer, %{})

    case validate_strict_params(prefer, params, resource_module) do
      :ok -> execute_list(conn, opts, resource_module, params, context, pipeline_opts)
      {:error, :unknown_params, unknown} -> send_strict_error(conn, opts, unknown)
    end
  rescue
    e in [Ecto.QueryError, Ecto.Query.CastError, ArgumentError] ->
      send_error(conn, opts, 422, Exception.message(e))
  end

  defp execute_list(conn, opts, resource_module, params, context, pipeline_opts) do
    accept = parse_accept_header(conn)
    prefer = Keyword.get(pipeline_opts, :prefer, %{})

    case QueryPipeline.execute_read(resource_module, params, context, pipeline_opts) do
      {:ok, records, range_info} ->
        conn
        |> put_preference_applied_header(prefer)
        |> put_content_range_header(range_info)
        |> maybe_single_response(opts, records, accept, range_status(range_info))

      {:ok, records} ->
        conn
        |> put_preference_applied_header(prefer)
        |> maybe_single_response(opts, records, accept, 200)

      {:error, reason} ->
        send_error(conn, opts, 422, format_error(reason))
    end
  end

  defp handle_show(conn, opts, resource_module, id, context) do
    pipeline_opts = build_pipeline_opts(conn, opts)
    prefer = Keyword.get(pipeline_opts, :prefer, %{})

    case validate_strict_params(prefer, conn.query_params, resource_module) do
      :ok -> execute_show(conn, opts, resource_module, id, context, pipeline_opts)
      {:error, :unknown_params, unknown} -> send_strict_error(conn, opts, unknown)
    end
  rescue
    e in [Ecto.QueryError, Ecto.Query.CastError, ArgumentError] ->
      send_error(conn, opts, 422, Exception.message(e))
  end

  defp execute_show(conn, opts, resource_module, id, context, pipeline_opts) do
    config = resource_module.__pgrest_config__()
    [pk_field] = config.primary_key
    pk_name = Atom.to_string(pk_field)
    params = Map.merge(conn.query_params, %{pk_name => "eq.#{id}"})

    case QueryPipeline.execute_read(resource_module, params, context, pipeline_opts) do
      {:ok, [record]} ->
        send_json(conn, opts, 200, record)

      {:ok, [record | _], _range_info} ->
        send_json(conn, opts, 200, record)

      {:ok, []} ->
        send_error(conn, opts, 404, "Not found")

      {:ok, [], _range_info} ->
        send_error(conn, opts, 404, "Not found")

      {:ok, [_ | _] = records} ->
        send_json(conn, opts, 200, hd(records))

      {:error, reason} ->
        send_error(conn, opts, 422, format_error(reason))
    end
  end

  defp handle_create(conn, opts, resource_module, context) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    prefer = parse_prefer_header(conn)
    config = resource_module.__pgrest_config__()

    case opts.json.decode(body) do
      {:ok, attrs} when is_list(attrs) ->
        handle_bulk_create(conn, opts, resource_module, config, attrs, context, prefer)

      {:ok, attrs} when is_map(attrs) ->
        if Map.has_key?(prefer, :resolution) do
          handle_upsert(conn, opts, resource_module, config, attrs, context, prefer)
        else
          handle_single_create(conn, opts, resource_module, config, attrs, context, prefer)
        end

      {:error, _} ->
        send_error(conn, opts, 400, "Invalid JSON")
    end
  end

  defp handle_single_create(conn, opts, resource_module, config, attrs, context, prefer) do
    case QueryPipeline.execute_create(resource_module, attrs, context) do
      {:ok, record} ->
        conn
        |> put_preference_applied_header(prefer)
        |> put_location_header(config, record)
        |> send_write_response(opts, :post, prefer, record, [record])

      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, opts, 422, format_changeset_errors(changeset))
    end
  end

  defp handle_bulk_create(conn, opts, resource_module, _config, attrs_list, context, prefer) do
    case QueryPipeline.execute_bulk_create(resource_module, attrs_list, context) do
      {:ok, records} ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :post, prefer, records, records)

      {:error, _idx, %Ecto.Changeset{} = changeset} ->
        send_error(conn, opts, 422, format_changeset_errors(changeset))
    end
  end

  defp handle_upsert(conn, opts, resource_module, _config, attrs, context, prefer) do
    on_conflict_param = conn.query_params["on_conflict"]

    upsert_opts = [
      resolution: prefer.resolution,
      on_conflict: on_conflict_param,
      missing_default: Map.get(prefer, :missing) == :default,
      return: Map.get(prefer, :return) == :representation
    ]

    case QueryPipeline.execute_upsert(resource_module, attrs, context, upsert_opts) do
      {:ok, _count, records} ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :post, prefer, records, records)

      {:ok, count} ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :post, prefer, %{count: count}, [])

      {:error, reason} ->
        send_error(conn, opts, 422, format_error(reason))
    end
  end

  defp handle_update(conn, opts, resource_module, id, context) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    prefer = parse_prefer_header(conn)

    case opts.json.decode(body) do
      {:ok, attrs} ->
        case QueryPipeline.execute_update(resource_module, id, attrs, context) do
          {:ok, record} ->
            conn
            |> put_preference_applied_header(prefer)
            |> send_write_response(opts, :patch, prefer, record, [record])

          {:error, :not_found} ->
            send_error(conn, opts, 404, "Not found")

          {:error, %Ecto.Changeset{} = changeset} ->
            send_error(conn, opts, 422, format_changeset_errors(changeset))
        end

      {:error, _} ->
        send_error(conn, opts, 400, "Invalid JSON")
    end
  end

  defp handle_bulk_update(conn, opts, resource_module, context) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    prefer = parse_prefer_header(conn)
    return_records? = Map.get(prefer, :return) == :representation

    case opts.json.decode(body) do
      {:ok, attrs} when is_map(attrs) ->
        pipeline_opts = [return: return_records?]

        case QueryPipeline.execute_bulk_update(
               resource_module,
               conn.query_params,
               attrs,
               context,
               pipeline_opts
             ) do
          {:ok, _count, records} when return_records? ->
            conn
            |> put_preference_applied_header(prefer)
            |> send_write_response(opts, :patch, prefer, records, records)

          {:ok, _count, _records} ->
            conn
            |> put_preference_applied_header(prefer)
            |> send_write_response(opts, :patch, prefer, nil, [])

          {:ok, _count} ->
            conn
            |> put_preference_applied_header(prefer)
            |> send_write_response(opts, :patch, prefer, nil, [])

          {:error, reason} ->
            send_error(conn, opts, 422, format_error(reason))
        end

      {:error, _} ->
        send_error(conn, opts, 400, "Invalid JSON")
    end
  rescue
    e in [Ecto.QueryError, Ecto.Query.CastError, Ecto.ConstraintError, ArgumentError] ->
      send_error(conn, opts, 422, Exception.message(e))
  end

  defp handle_delete(conn, opts, resource_module, id, context) do
    prefer = parse_prefer_header(conn)

    case QueryPipeline.execute_delete(resource_module, id, context) do
      {:ok, record} ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :delete, prefer, record, [record])

      {:error, :not_found} ->
        send_error(conn, opts, 404, "Not found")

      {:error, reason} ->
        send_error(conn, opts, 422, format_error(reason))
    end
  end

  defp handle_bulk_delete(conn, opts, resource_module, context) do
    prefer = parse_prefer_header(conn)
    return_records? = Map.get(prefer, :return) == :representation

    pipeline_opts = [return: return_records?]

    case QueryPipeline.execute_bulk_delete(
           resource_module,
           conn.query_params,
           context,
           pipeline_opts
         ) do
      {:ok, _count, records} when return_records? ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :delete, prefer, records, records)

      {:ok, _count, _records} ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :delete, prefer, nil, [])

      {:ok, _count} ->
        conn
        |> put_preference_applied_header(prefer)
        |> send_write_response(opts, :delete, prefer, nil, [])

      {:error, reason} ->
        send_error(conn, opts, 422, format_error(reason))
    end
  rescue
    e in [Ecto.QueryError, Ecto.Query.CastError, Ecto.ConstraintError, ArgumentError] ->
      send_error(conn, opts, 422, Exception.message(e))
  end

  # --- Strict Parameter Validation ---

  @standard_query_params ~w(select order limit offset on_conflict columns and or)

  defp validate_strict_params(%{handling: :strict}, params, resource_module) do
    config = resource_module.__pgrest_config__()
    field_strings = Enum.map(config.fields, &Atom.to_string/1)

    unknown =
      params
      |> Map.keys()
      |> Enum.reject(fn key ->
        key in @standard_query_params or
          key in field_strings or
          String.starts_with?(key, "not.") or
          String.contains?(key, ".")
      end)

    case unknown do
      [] -> :ok
      keys -> {:error, :unknown_params, keys}
    end
  end

  defp validate_strict_params(_prefer, _params, _resource_module), do: :ok

  defp send_strict_error(conn, opts, unknown_keys) do
    send_error(conn, opts, 400, "Unknown parameters: #{Enum.join(unknown_keys, ", ")}")
  end

  # --- Prefer Header Parsing ---

  defp parse_prefer_header(conn) do
    conn
    |> Plug.Conn.get_req_header("prefer")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(%{}, fn
      "return=representation", acc -> Map.put(acc, :return, :representation)
      "return=minimal", acc -> Map.put(acc, :return, :minimal)
      "return=headers-only", acc -> Map.put(acc, :return, :headers_only)
      "resolution=merge-duplicates", acc -> Map.put(acc, :resolution, :merge_duplicates)
      "resolution=ignore-duplicates", acc -> Map.put(acc, :resolution, :ignore_duplicates)
      "missing=default", acc -> Map.put(acc, :missing, :default)
      "handling=strict", acc -> Map.put(acc, :handling, :strict)
      "handling=lenient", acc -> Map.put(acc, :handling, :lenient)
      "count=exact", acc -> Map.put(acc, :count, :exact)
      "count=planned", acc -> Map.put(acc, :count, :planned)
      "count=estimated", acc -> Map.put(acc, :count, :estimated)
      _, acc -> acc
    end)
  end

  defp parse_accept_header(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "application/vnd.pgrst.object+json"))
    |> case do
      true -> :single_object
      false -> :json
    end
  end

  defp put_preference_applied_header(conn, prefer) when map_size(prefer) == 0, do: conn

  defp put_preference_applied_header(conn, prefer) do
    parts =
      prefer
      |> Enum.map(fn
        {:return, :representation} -> "return=representation"
        {:return, :minimal} -> "return=minimal"
        {:return, :headers_only} -> "return=headers-only"
        {:resolution, :merge_duplicates} -> "resolution=merge-duplicates"
        {:resolution, :ignore_duplicates} -> "resolution=ignore-duplicates"
        {:missing, :default} -> "missing=default"
        {:handling, :strict} -> "handling=strict"
        {:handling, :lenient} -> "handling=lenient"
        {:count, :exact} -> "count=exact"
        {:count, :planned} -> "count=planned"
        {:count, :estimated} -> "count=estimated"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> conn
      parts -> Plug.Conn.put_resp_header(conn, "preference-applied", Enum.join(parts, ", "))
    end
  end

  # --- Response Control ---

  defp send_write_response(conn, opts, method, prefer, _data, records) do
    accept = parse_accept_header(conn)
    return_mode = Map.get(prefer, :return)

    case return_mode do
      :representation ->
        body =
          case {accept, records} do
            {:single_object, [single]} -> single
            {_, records} when is_list(records) -> records
          end

        status = if method == :post, do: 201, else: 200
        send_json(conn, opts, status, body)

      :headers_only ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(204, "")
        |> Plug.Conn.halt()

      _ ->
        # :minimal or nil (default) — empty body
        status = if method == :post, do: 201, else: 204

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, "")
        |> Plug.Conn.halt()
    end
  end

  defp put_location_header(conn, config, record) when is_map(record) do
    [pk_field] = config.primary_key

    case Map.get(record, pk_field) do
      nil ->
        conn

      pk_value ->
        table = config.table
        location = "/#{table}?#{Atom.to_string(pk_field)}=eq.#{pk_value}"
        Plug.Conn.put_resp_header(conn, "location", location)
    end
  end

  defp maybe_single_response(conn, opts, records, :single_object, _status) do
    case records do
      [single] ->
        send_json(conn, opts, 200, single)

      _ ->
        send_error(conn, opts, 406, "JSON object requested, multiple (or no) rows returned")
    end
  end

  defp maybe_single_response(conn, opts, records, :json, status) do
    send_json(conn, opts, status, records)
  end

  # --- Context Building ---

  defp build_context(conn, %{context_builder: fun} = opts) when is_function(fun, 2) do
    fun.(conn, opts)
  end

  defp build_context(conn, opts) do
    default_context_builder(conn, opts)
  end

  defp default_context_builder(conn, opts) do
    assigns = conn.assigns

    %{
      repo: opts.repo,
      user_id: Map.get(assigns, :user_id),
      role: Map.get(assigns, :role),
      tenant_id: Map.get(assigns, :tenant_id),
      assigns: assigns
    }
  end

  defp build_pipeline_opts(conn, opts) do
    prefer = parse_prefer_header(conn)
    [max_limit: opts.max_limit, prefer: prefer]
  end

  # --- Content Range ---

  defp put_content_range_header(conn, range_info) do
    header = format_content_range(range_info)
    Plug.Conn.put_resp_header(conn, "content-range", header)
  end

  defp format_content_range(%{count: 0, total: total}) do
    "*/#{format_total(total)}"
  end

  defp format_content_range(%{offset: offset, count: count, total: total}) do
    last = offset + count - 1
    "#{offset}-#{last}/#{format_total(total)}"
  end

  defp format_total(nil), do: "*"
  defp format_total(total), do: Integer.to_string(total)

  # PostgREST status codes:
  # - 200: no total known, or returned range covers entire dataset
  # - 206: returned rows fewer than total (partial content)
  # - 416: offset beyond total (range not satisfiable)
  defp range_status(%{total: nil}), do: 200
  defp range_status(%{offset: offset, total: total}) when offset > total, do: 416
  defp range_status(%{count: count, total: total}) when count >= total, do: 200
  defp range_status(%{offset: 0, count: count, total: total}) when count >= total, do: 200
  defp range_status(%{total: _total}), do: 206

  # --- JSON Response ---

  defp send_json(conn, opts, status, data) do
    sanitized = sanitize_for_json(data)
    restricted = maybe_restrict_to_select(sanitized, conn.query_params)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, opts.json.encode!(restricted))
    |> Plug.Conn.halt()
  end

  # List of records — map over each
  defp sanitize_for_json(records) when is_list(records),
    do: Enum.map(records, &sanitize_for_json/1)

  # Ecto struct (has __meta__) — convert to map, drop __meta__ + NotLoaded, recurse values
  defp sanitize_for_json(%{__struct__: _, __meta__: _} = record) do
    record
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Enum.reduce(%{}, fn
      {_key, %Ecto.Association.NotLoaded{}}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, sanitize_for_json(value))
    end)
  end

  # Everything else passes through unchanged
  defp sanitize_for_json(value), do: value

  # --- Select Field Restriction ---
  #
  # PostgREST only returns requested columns. When `select=id,name` is used,
  # Ecto's `struct(r, [:id, :name])` still returns a full schema struct where
  # unselected fields carry default values (usually nil). This strips those
  # unselected fields from the serialized output so the JSON matches PostgREST.

  # NOTE: Select AST is parsed twice — once in Parser.parse/2 during QueryPipeline.execute_read,
  # and again here. Thread the parsed AST through conn.private when the Plug is decomposed
  # into smaller modules to avoid the redundant parse.
  defp maybe_restrict_to_select(data, %{"select" => "*"}), do: data

  defp maybe_restrict_to_select(data, %{"select" => select_str}) when is_binary(select_str) do
    {:ok, ast} = Select.parse(select_str)
    apply_select_mask(data, ast)
  end

  defp maybe_restrict_to_select(data, _params), do: data

  # Wildcard in root select — no restriction needed
  defp apply_select_mask(data, ast) do
    has_wildcard? = Enum.any?(ast, &match?(%{type: :field, name: "*"}, &1))
    do_apply_select_mask(data, ast, has_wildcard?)
  end

  defp do_apply_select_mask(data, _ast, true), do: data

  defp do_apply_select_mask(data, ast, false) do
    mask = Enum.map(ast, &ast_node_to_mask/1) |> Map.new()
    apply_mask(data, mask)
  end

  # Convert each select AST node into a {key, mask} pair
  defp ast_node_to_mask(%{type: :field, name: name}),
    do: {String.to_existing_atom(name), :keep}

  defp ast_node_to_mask(%{type: :embed, name: name, fields: fields}),
    do: {String.to_existing_atom(name), fields_to_mask(fields)}

  # Convert embed inner fields into a mask
  defp fields_to_mask(["*"]), do: :keep
  defp fields_to_mask(fields), do: do_fields_to_mask(fields, Enum.member?(fields, "*"))

  defp do_fields_to_mask(_fields, true), do: :keep
  defp do_fields_to_mask(fields, false), do: Enum.map(fields, &field_to_mask/1) |> Map.new()

  defp field_to_mask(%{type: :embed, name: name, fields: inner}),
    do: {String.to_existing_atom(name), fields_to_mask(inner)}

  defp field_to_mask(name) when is_binary(name),
    do: {String.to_existing_atom(name), :keep}

  # Recursively apply mask to data
  defp apply_mask(data, mask) when is_list(data),
    do: Enum.map(data, &apply_mask(&1, mask))

  defp apply_mask(data, :keep), do: data

  defp apply_mask(data, mask) when is_map(data) and is_map(mask) do
    Map.new(mask, fn {key, sub_mask} ->
      {key, apply_mask(Map.get(data, key), sub_mask)}
    end)
  end

  defp apply_mask(data, _mask), do: data

  defp send_error(conn, opts, status, reason) when is_atom(reason) do
    send_error(conn, opts, status, Atom.to_string(reason))
  end

  defp send_error(conn, opts, status, message) when is_binary(message) do
    body = opts.json.encode!(%{error: message})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp send_error(conn, opts, status, errors) when is_map(errors) do
    body = opts.json.encode!(%{errors: errors})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
