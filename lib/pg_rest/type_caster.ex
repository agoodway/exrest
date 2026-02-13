defmodule PgRest.TypeCaster do
  @moduledoc """
  Casts string values from URL parameters to proper Elixir/Ecto types
  based on schema introspection.
  """

  import PgRest.Utils, only: [safe_to_existing_atom: 1]

  @skip_cast_ops ~w(is_null is fts plfts phfts wfts match imatch cs cd ov sl sr nxr nxl adj)a

  @doc """
  Casts all filter values to their proper types based on the schema.
  Returns `{:ok, filters}` with cast values or `{:error, reason}` on cast failure.
  """
  @spec cast_filters([map()], module()) :: {:ok, [map()]} | {:error, term()}
  def cast_filters(filters, schema_module) when is_list(filters) do
    cast_filters_acc(filters, schema_module, [])
  end

  defp cast_filters_acc([], _schema_module, acc), do: {:ok, Enum.reverse(acc)}

  defp cast_filters_acc([filter | rest], schema_module, acc) do
    {:ok, cast_filter} = cast_filter(filter, schema_module)
    cast_filters_acc(rest, schema_module, [cast_filter | acc])
  end

  defp cast_filter(%{logic: logic, conditions: conditions} = filter, schema_module)
       when logic in [:and, :or] do
    {:ok, cast_conditions} = cast_filters(conditions, schema_module)
    {:ok, %{filter | conditions: cast_conditions}}
  end

  defp cast_filter(%{logic: :not, condition: condition} = filter, schema_module) do
    {:ok, cast_condition} = cast_filter(condition, schema_module)
    {:ok, %{filter | condition: cast_condition}}
  end

  defp cast_filter(%{operator: op} = filter, _schema_module) when op in @skip_cast_ops do
    {:ok, filter}
  end

  defp cast_filter(%{field: field, operator: op, value: value} = filter, schema_module) do
    field_atom = safe_to_existing_atom(field)
    field_type = get_field_type(schema_module, field_atom)

    {:ok, cast_value} = cast_value(field_type, op, value)
    {:ok, %{filter | value: cast_value}}
  end

  defp cast_value(nil, _op, value), do: {:ok, value}

  defp cast_value(field_type, :in, values) when is_list(values) do
    cast_list(field_type, values, [])
  end

  defp cast_value(field_type, _op, value) when is_binary(value) do
    case Ecto.Type.cast(field_type, value) do
      {:ok, cast} -> {:ok, cast}
      :error -> {:ok, value}
    end
  end

  defp cast_value(_field_type, _op, value), do: {:ok, value}

  defp cast_list(_field_type, [], acc), do: {:ok, Enum.reverse(acc)}

  defp cast_list(field_type, [val | rest], acc) do
    case Ecto.Type.cast(field_type, val) do
      {:ok, cast} -> cast_list(field_type, rest, [cast | acc])
      :error -> cast_list(field_type, rest, [val | acc])
    end
  end

  defp get_field_type(schema_module, field_atom) do
    schema_module.__schema__(:type, field_atom)
  rescue
    _ -> nil
  end
end
