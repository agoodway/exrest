defmodule PgRest.Parser.Order do
  @moduledoc """
  Parses PostgREST order parameter into ordering directives.

  Examples:
    - "created_at.desc.nullslast" -> [%{field: "created_at", direction: :desc, nulls: :last}]
    - "name.asc" -> [%{field: "name", direction: :asc, nulls: nil}]
    - "name" -> [%{field: "name", direction: :asc, nulls: nil}]
  """

  @doc """
  Parses an order parameter string into a list of ordering directives.

  Each directive contains `:field`, `:direction` (`:asc` or `:desc`),
  and `:nulls` (`:first`, `:last`, or `nil`).
  """
  @spec parse(String.t()) :: {:ok, [map()]}
  def parse(order_str) when is_binary(order_str) do
    directives =
      order_str
      |> String.split(",")
      |> Enum.map(&parse_directive/1)

    {:ok, directives}
  end

  defp parse_directive(str) do
    parts = String.split(String.trim(str), ".")

    case parts do
      [field] ->
        %{field: field, direction: :asc, nulls: nil}

      [field, direction] ->
        %{field: field, direction: parse_direction(direction), nulls: nil}

      [field, direction, nulls] ->
        %{field: field, direction: parse_direction(direction), nulls: parse_nulls(nulls)}

      _ ->
        %{field: hd(parts), direction: :asc, nulls: nil}
    end
  end

  defp parse_direction("desc"), do: :desc
  defp parse_direction("asc"), do: :asc
  defp parse_direction(_), do: :asc

  defp parse_nulls("nullsfirst"), do: :first
  defp parse_nulls("nullslast"), do: :last
  defp parse_nulls(_), do: nil
end
