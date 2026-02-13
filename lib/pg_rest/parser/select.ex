defmodule PgRest.Parser.Select do
  @moduledoc """
  Parses PostgREST select parameter into an AST.

  Supports field selection, embed preloading with `!inner` modifier,
  embed aliasing via `alias:name(...)`, nested embeds, and empty
  embeds for anti-joins.

  ## Examples

      iex> PgRest.Parser.Select.parse("id,name,email")
      {:ok, [%{type: :field, name: "id"}, %{type: :field, name: "name"}, %{type: :field, name: "email"}]}

      iex> PgRest.Parser.Select.parse("id,posts(id,title)")
      {:ok, [%{type: :field, name: "id"}, %{type: :embed, name: "posts", fields: ["id", "title"], inner: false}]}

  """

  @doc """
  Parses a select parameter string into a list of field and embed AST nodes.
  """
  @spec parse(String.t()) :: {:ok, [map()]}
  def parse(select_str) when is_binary(select_str) do
    fields = parse_fields(select_str)
    {:ok, fields}
  end

  defp parse_fields(str) do
    str
    |> split_top_level()
    |> Enum.map(&parse_field/1)
  end

  # Parses a single field or embed expression.
  defp parse_field(field_str) do
    field_str = String.trim(field_str)
    {alias_name, rest} = extract_alias(field_str)

    case parse_embed(rest) do
      {:embed, name, inner?, inner_str} ->
        fields = parse_inner_fields(inner_str)
        embed = %{type: :embed, name: name, fields: fields, inner: inner?}
        if alias_name, do: Map.put(embed, :alias, alias_name), else: embed

      :not_embed ->
        %{type: :field, name: rest}
    end
  end

  # Extracts an optional alias prefix from "alias:rest" syntax.
  # Returns `{alias, rest}` or `{nil, original}`.
  defp extract_alias(str) do
    case Regex.run(~r/^(\w+):(.+)$/, str) do
      [_, alias_name, rest] -> {alias_name, rest}
      nil -> {nil, str}
    end
  end

  # Parses embed syntax variants:
  # - "name(fields)"       -> standard embed
  # - "name!inner(fields)" -> inner join embed
  # - "name()"             -> empty embed (for anti-joins)
  defp parse_embed(str) do
    case Regex.run(~r/^(\w+)(!inner)?\((.*)\)$/s, str) do
      [_, name, "!inner", inner] -> {:embed, name, true, inner}
      [_, name, "", inner] -> {:embed, name, false, inner}
      nil -> :not_embed
    end
  end

  # Recursively parses the fields inside embed parentheses.
  # Returns a list of strings (field names) and nested embed maps.
  defp parse_inner_fields(""), do: []
  defp parse_inner_fields("*"), do: ["*"]

  defp parse_inner_fields(inner_str) do
    inner_str
    |> split_top_level()
    |> Enum.map(&parse_field/1)
    |> Enum.map(fn
      %{type: :field, name: name} -> name
      %{type: :embed} = nested -> nested
    end)
  end

  # Splits a string on top-level commas, respecting nested parentheses.
  defp split_top_level(str), do: do_split(str, 0, "", [])

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
end
