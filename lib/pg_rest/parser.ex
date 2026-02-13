defmodule PgRest.Parser do
  @moduledoc """
  Parses PostgREST-style URL parameters into structured ASTs.

  Handles filters, select, order, pagination, embed filters (dot-notation),
  custom params, on_conflict, and columns.
  """

  alias PgRest.Parser.{Order, Select}

  @standard_params ~w(select order limit offset on_conflict columns)

  @doc """
  Parses a map of URL query parameters into a structured result.

  ## Options

    * `:allowed_fields` - list of atoms restricting which fields can be filtered
    * `:max_limit` - integer clamping the maximum limit value

  ## Returns

    `{:ok, parsed}` where parsed contains:
    * `:filters` - list of filter AST nodes for the root resource
    * `:embed_filters` - map of embed name to list of filter AST nodes
    * `:select` - select AST or nil
    * `:order` - order AST or nil
    * `:limit`, `:offset` - pagination values
    * `:custom_params` - params not matching any known field or standard param
    * `:on_conflict`, `:columns` - upsert-related params
  """
  @spec parse(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(params, opts \\ []) when is_map(params) do
    allowed_fields = Keyword.get(opts, :allowed_fields)
    max_limit = Keyword.get(opts, :max_limit)

    with {:ok, select} <- parse_select(params),
         {:ok, order} <- parse_order(params),
         {:ok, pagination} <- parse_pagination(params, max_limit),
         {:ok, filters, embed_filters, embed_options} <-
           parse_all_filters(params, allowed_fields, select),
         {:ok, custom_params} <- extract_custom_params(params, allowed_fields, select) do
      {:ok,
       %{
         filters: filters,
         embed_filters: embed_filters,
         embed_options: embed_options,
         select: select,
         order: order,
         limit: pagination.limit,
         offset: pagination.offset,
         custom_params: custom_params,
         on_conflict: Map.get(params, "on_conflict"),
         columns: parse_columns(params)
       }}
    end
  end

  # --- Select ---

  defp parse_select(%{"select" => "*"}), do: {:ok, nil}

  defp parse_select(%{"select" => select_str}) when is_binary(select_str),
    do: Select.parse(select_str)

  defp parse_select(_), do: {:ok, nil}

  # --- Order ---

  defp parse_order(%{"order" => order_str}) when is_binary(order_str),
    do: Order.parse(order_str)

  defp parse_order(_), do: {:ok, nil}

  # --- Pagination ---

  defp parse_pagination(params, max_limit) do
    with {:ok, limit} <- parse_int_param(params, "limit"),
         {:ok, offset} <- parse_int_param(params, "offset"),
         :ok <- validate_non_negative(limit, :invalid_limit),
         :ok <- validate_non_negative(offset, :invalid_offset) do
      {:ok, %{limit: clamp_limit(limit, max_limit), offset: offset}}
    end
  end

  defp validate_non_negative(nil, _error), do: :ok
  defp validate_non_negative(val, _error) when val >= 0, do: :ok
  defp validate_non_negative(_val, error), do: {:error, error}

  defp clamp_limit(nil, nil), do: nil
  defp clamp_limit(nil, max_limit) when is_integer(max_limit), do: max_limit
  defp clamp_limit(limit, nil) when is_integer(limit), do: limit

  defp clamp_limit(limit, max_limit) when is_integer(limit) and is_integer(max_limit),
    do: min(limit, max_limit)

  defp parse_int_param(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      val when is_binary(val) -> parse_int_string(val, key)
      val when is_integer(val) -> {:ok, val}
    end
  end

  defp parse_int_string(val, key) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _ -> {:error, invalid_param_error(key)}
    end
  end

  defp invalid_param_error("limit"), do: :invalid_limit
  defp invalid_param_error("offset"), do: :invalid_offset

  # --- Filters ---

  # Parses all query params into root-level filters, embed filters, and embed options.
  # Embed filters use dot-notation: `assoc_name.field=op.value`.
  # Embed existence filters use: `assoc_name=is.null`.
  # Embed options use: `assoc_name.order`, `assoc_name.limit`, `assoc_name.offset`.
  defp parse_all_filters(params, allowed_fields, select) do
    embed_names = extract_embed_names(select)

    result =
      Enum.reduce_while(params, {[], %{}, %{}}, fn {key, value}, acc ->
        classify_and_parse(key, value, acc, allowed_fields, embed_names)
      end)

    case result do
      {:error, _} = err ->
        err

      {filters, embed_filters, embed_options} ->
        {:ok, Enum.reverse(filters), embed_filters, embed_options}
    end
  end

  # Routes each param to the appropriate handler based on its shape.
  defp classify_and_parse(key, _value, acc, _allowed_fields, _embed_names)
       when key in @standard_params,
       do: {:cont, acc}

  defp classify_and_parse(key, value, {filters, embeds, opts}, _allowed_fields, _embed_names)
       when key in ["and", "or"] do
    case parse_logical(key, value) do
      {:ok, logical} -> {:cont, {[logical | filters], embeds, opts}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp classify_and_parse(
         "not." <> field,
         value,
         {filters, embeds, opts},
         allowed_fields,
         _embed_names
       ) do
    if allowed_field?(field, allowed_fields) do
      case parse_operator_value(value) do
        {:ok, op, val} ->
          filter = %{logic: :not, condition: %{field: field, operator: op, value: val}}
          {:cont, {[filter | filters], embeds, opts}}

        {:error, _} = err ->
          {:halt, err}
      end
    else
      {:cont, {filters, embeds, opts}}
    end
  end

  defp classify_and_parse(key, value, {filters, embeds, opts}, allowed_fields, embed_names) do
    cond do
      embed_option_key?(key, embed_names) ->
        handle_embed_option(key, value, filters, embeds, opts)

      embed_dot_filter?(key, embed_names) ->
        handle_embed_dot_filter(key, value, filters, embeds, opts)

      embed_null_filter?(key, embed_names) ->
        handle_embed_null_filter(key, value, filters, embeds, opts)

      allowed_field?(key, allowed_fields) ->
        handle_field_filter(key, value, filters, embeds, opts)

      true ->
        {:cont, {filters, embeds, opts}}
    end
  end

  # Handles `assoc_name.order`, `assoc_name.limit`, `assoc_name.offset` params.
  defp handle_embed_option(key, value, filters, embeds, opts) do
    [embed_name, option] = String.split(key, ".", parts: 2)

    case parse_embed_option(option, value) do
      {:ok, opt_key, opt_val} ->
        existing = Map.get(opts, embed_name, %{})
        updated = Map.put(existing, opt_key, opt_val)
        {:cont, {filters, embeds, Map.put(opts, embed_name, updated)}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  defp parse_embed_option("order", value) do
    {:ok, directives} = Order.parse(value)
    {:ok, :order, directives}
  end

  defp parse_embed_option("limit", value) do
    case parse_embed_int(value) do
      {:ok, int} when int >= 0 -> {:ok, :limit, int}
      {:ok, _} -> {:error, :invalid_embed_limit}
      {:error, _} = err -> err
    end
  end

  defp parse_embed_option("offset", value) do
    case parse_embed_int(value) do
      {:ok, int} when int >= 0 -> {:ok, :offset, int}
      {:ok, _} -> {:error, :invalid_embed_offset}
      {:error, _} = err -> err
    end
  end

  defp parse_embed_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_embed_option}
    end
  end

  defp parse_embed_int(value) when is_integer(value), do: {:ok, value}

  # Handles `assoc_name.field=op.value` and `assoc_name.nested.field=op.value` params.
  # For multi-level dot-notation (e.g., `posts.comments.status`), the last segment
  # is the field name and everything before it is the embed path key.
  defp handle_embed_dot_filter(key, value, filters, embeds, opts) do
    parts = String.split(key, ".")
    {path_parts, [field_name]} = Enum.split(parts, -1)
    embed_key = Enum.join(path_parts, ".")

    case parse_operator_value(value) do
      {:ok, op, val} ->
        filter = %{field: field_name, operator: op, value: val}
        existing = Map.get(embeds, embed_key, [])
        {:cont, {filters, Map.put(embeds, embed_key, [filter | existing]), opts}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  # Handles `assoc_name=is.null` or `assoc_name=not.is.null` params.
  defp handle_embed_null_filter(key, value, filters, embeds, opts) do
    case parse_operator_value(value) do
      {:ok, op, val} ->
        filter = %{field: :__embed_exists__, operator: op, value: val}
        {:cont, {filters, Map.put(embeds, key, [filter]), opts}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  # Handles standard `field=op.value` params on the root resource.
  defp handle_field_filter(key, value, filters, embeds, opts) do
    case parse_operator_value(value) do
      {:ok, op, val} ->
        {:cont, {[%{field: key, operator: op, value: val} | filters], embeds, opts}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  # --- Embed Name Detection ---

  defp extract_embed_names(nil), do: []

  defp extract_embed_names(select) when is_list(select) do
    select
    |> Enum.filter(&match?(%{type: :embed}, &1))
    |> Enum.map(& &1.name)
  end

  @embed_option_names ~w(order limit offset)

  # Checks if a param key is an embed option (order/limit/offset).
  defp embed_option_key?(key, embed_names) do
    case String.split(key, ".", parts: 2) do
      [embed_name, option] -> embed_name in embed_names and option in @embed_option_names
      _ -> false
    end
  end

  # Checks if a param key is a dot-notation embed filter.
  defp embed_dot_filter?(key, embed_names) do
    case String.split(key, ".", parts: 2) do
      [embed_name, _rest] -> embed_name in embed_names
      _ -> false
    end
  end

  # Checks if a param key is a bare embed name (for null/not-null checks).
  defp embed_null_filter?(key, embed_names), do: key in embed_names

  # --- Custom Params ---

  defp extract_custom_params(params, allowed_fields, select) do
    embed_names = extract_embed_names(select)

    custom =
      params
      |> Enum.reject(fn {key, _} ->
        key in @standard_params or
          key in ["and", "or"] or
          String.starts_with?(key, "not.") or
          allowed_field?(key, allowed_fields) or
          embed_option_key?(key, embed_names) or
          embed_dot_filter?(key, embed_names) or
          embed_null_filter?(key, embed_names)
      end)
      |> Map.new()

    {:ok, custom}
  end

  defp allowed_field?(_field, nil), do: true

  defp allowed_field?(field, allowed_fields) when is_list(allowed_fields) do
    field in Enum.map(allowed_fields, &to_string/1)
  end

  # --- Operator Parsing ---

  @doc """
  Parses an operator.value string into `{:ok, operator, value}`.

  ## Examples

      iex> PgRest.Parser.parse_operator_value("eq.active")
      {:ok, :eq, "active"}

      iex> PgRest.Parser.parse_operator_value("in.(a,b,c)")
      {:ok, :in, ["a", "b", "c"]}

  """
  @spec parse_operator_value(String.t()) :: {:ok, atom(), term()} | {:error, term()}
  def parse_operator_value(str) when is_binary(str) do
    parse_comparison_op(str) || parse_special_op(str) || {:error, {:invalid_operator, str}}
  end

  @simple_ops ~w(eq neq gt gte lt lte like ilike match imatch isdistinct cs cd ov sl sr nxr nxl adj)

  defp parse_comparison_op(str) do
    Enum.find_value(@simple_ops, fn op ->
      prefix = op <> "."

      case str do
        <<^prefix::binary-size(byte_size(prefix)), val::binary>> ->
          {:ok, String.to_existing_atom(op), val}

        _ ->
          nil
      end
    end)
  end

  defp parse_special_op("in.(" <> rest), do: parse_in_value(rest)
  defp parse_special_op("is." <> val), do: parse_is_value(val)
  defp parse_special_op("fts(" <> rest), do: parse_fts_config(rest, :fts)
  defp parse_special_op("fts." <> val), do: {:ok, :fts, {"english", val}}
  defp parse_special_op("plfts(" <> rest), do: parse_fts_config(rest, :plfts)
  defp parse_special_op("plfts." <> val), do: {:ok, :plfts, {"english", val}}
  defp parse_special_op("phfts(" <> rest), do: parse_fts_config(rest, :phfts)
  defp parse_special_op("phfts." <> val), do: {:ok, :phfts, {"english", val}}
  defp parse_special_op("wfts(" <> rest), do: parse_fts_config(rest, :wfts)
  defp parse_special_op("wfts." <> val), do: {:ok, :wfts, {"english", val}}
  defp parse_special_op(_), do: nil

  defp parse_in_value(rest) do
    size = byte_size(rest) - 1

    case rest do
      <<values::binary-size(size), ")">> ->
        {:ok, :in, String.split(values, ",")}

      _ ->
        {:error, {:invalid_in, rest}}
    end
  end

  defp parse_is_value("null"), do: {:ok, :is_null, true}
  defp parse_is_value("not_null"), do: {:ok, :is_null, false}
  defp parse_is_value("true"), do: {:ok, :is, true}
  defp parse_is_value("false"), do: {:ok, :is, false}
  defp parse_is_value("unknown"), do: {:ok, :is_null, true}
  defp parse_is_value(other), do: {:error, {:invalid_is, other}}

  defp parse_fts_config(rest, op) do
    case String.split(rest, ").", parts: 2) do
      [lang, val] -> {:ok, op, {lang, val}}
      _ -> {:error, {:invalid_fts, rest}}
    end
  end

  # --- Logical Operators ---

  defp parse_logical(logic_type, value) when is_binary(value) do
    logic = String.to_existing_atom(logic_type)
    inner = value |> String.trim_leading("(") |> String.trim_trailing(")")

    conditions =
      inner
      |> split_logical_conditions()
      |> Enum.reduce_while([], fn condition, acc ->
        case parse_condition_string(condition) do
          {:ok, filter} -> {:cont, [filter | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case conditions do
      {:error, _} = err -> err
      list -> {:ok, %{logic: logic, conditions: Enum.reverse(list)}}
    end
  end

  # Splits on commas, respecting nested parentheses for `in.(...)`.
  defp split_logical_conditions(str), do: do_split(str, 0, "", [])

  defp do_split("", _depth, current, acc),
    do: Enum.reverse([current | acc])

  defp do_split("(" <> rest, depth, current, acc),
    do: do_split(rest, depth + 1, current <> "(", acc)

  defp do_split(")" <> rest, depth, current, acc) when depth > 0,
    do: do_split(rest, depth - 1, current <> ")", acc)

  defp do_split("," <> rest, 0, current, acc),
    do: do_split(rest, 0, "", [current | acc])

  defp do_split(<<char::binary-size(1), rest::binary>>, depth, current, acc),
    do: do_split(rest, depth, current <> char, acc)

  defp parse_condition_string(condition) do
    case String.split(condition, ".", parts: 2) do
      [field, op_val] ->
        case parse_operator_value(op_val) do
          {:ok, op, val} -> {:ok, %{field: field, operator: op, value: val}}
          {:error, _} = err -> err
        end

      _ ->
        {:error, {:invalid_condition, condition}}
    end
  end

  # --- Columns ---

  defp parse_columns(%{"columns" => columns}) when is_binary(columns) do
    columns
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_columns(_), do: nil
end
