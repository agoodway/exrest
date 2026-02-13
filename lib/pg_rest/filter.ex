defmodule PgRest.Filter do
  @moduledoc """
  Applies parsed filter ASTs to Ecto queries.
  """

  import Ecto.Query
  import PgRest.Utils, only: [safe_to_atom: 1]

  @doc """
  Applies a list of parsed filter ASTs to an Ecto query.
  """
  @spec apply_all(Ecto.Queryable.t(), [map()]) :: Ecto.Query.t()
  def apply_all(query, filters) when is_list(filters) do
    Enum.reduce(filters, query, &apply_filter/2)
  end

  @doc """
  Applies a single filter AST node to an Ecto query.

  Handles simple field filters, logical operators (`:and`, `:or`, `:not`),
  and all PostgREST comparison operators.
  """
  @spec apply_filter(map(), Ecto.Queryable.t()) :: Ecto.Query.t()
  def apply_filter(%{logic: :and, conditions: conditions}, query) do
    Enum.reduce(conditions, query, &apply_filter/2)
  end

  def apply_filter(%{logic: :or, conditions: conditions}, query) do
    dynamic = build_or_dynamic(conditions)
    where(query, ^dynamic)
  end

  def apply_filter(%{logic: :not, condition: condition}, query) do
    dynamic = build_dynamic(condition)
    where(query, [r], not (^dynamic))
  end

  def apply_filter(%{field: field, operator: op, value: value}, query) do
    field_atom = safe_to_atom(field)
    apply_op(query, field_atom, op, value)
  end

  # Comparison operators
  defp apply_op(query, field, :eq, value) do
    where(query, [r], field(r, ^field) == ^value)
  end

  defp apply_op(query, field, :neq, value) do
    where(query, [r], field(r, ^field) != ^value)
  end

  defp apply_op(query, field, :gt, value) do
    where(query, [r], field(r, ^field) > ^value)
  end

  defp apply_op(query, field, :gte, value) do
    where(query, [r], field(r, ^field) >= ^value)
  end

  defp apply_op(query, field, :lt, value) do
    where(query, [r], field(r, ^field) < ^value)
  end

  defp apply_op(query, field, :lte, value) do
    where(query, [r], field(r, ^field) <= ^value)
  end

  # Pattern matching — PostgREST only converts * to %, no auto-wrap
  defp apply_op(query, field, :like, value) do
    pattern = convert_wildcards(value)
    where(query, [r], like(field(r, ^field), ^pattern))
  end

  defp apply_op(query, field, :ilike, value) do
    pattern = convert_wildcards(value)
    where(query, [r], ilike(field(r, ^field), ^pattern))
  end

  # POSIX regex
  defp apply_op(query, field, :match, value) do
    where(query, [r], fragment("? ~ ?", field(r, ^field), ^value))
  end

  defp apply_op(query, field, :imatch, value) do
    where(query, [r], fragment("? ~* ?", field(r, ^field), ^value))
  end

  # IN operator
  defp apply_op(query, field, :in, values) when is_list(values) do
    where(query, [r], field(r, ^field) in ^values)
  end

  # IS NULL
  defp apply_op(query, field, :is_null, true) do
    where(query, [r], is_nil(field(r, ^field)))
  end

  defp apply_op(query, field, :is_null, false) do
    where(query, [r], not is_nil(field(r, ^field)))
  end

  # IS boolean
  defp apply_op(query, field, :is, true) do
    where(query, [r], field(r, ^field) == true)
  end

  defp apply_op(query, field, :is, false) do
    where(query, [r], field(r, ^field) == false)
  end

  # IS DISTINCT FROM
  defp apply_op(query, field, :isdistinct, value) do
    where(query, [r], fragment("? IS DISTINCT FROM ?", field(r, ^field), ^value))
  end

  # Array containment
  defp apply_op(query, field, :cs, value) do
    array_val = parse_pg_array(value)
    where(query, [r], fragment("? @> ?", field(r, ^field), ^array_val))
  end

  defp apply_op(query, field, :cd, value) do
    array_val = parse_pg_array(value)
    where(query, [r], fragment("? <@ ?", field(r, ^field), ^array_val))
  end

  # Array overlap
  defp apply_op(query, field, :ov, value) do
    array_val = parse_pg_array(value)
    where(query, [r], fragment("? && ?", field(r, ^field), ^array_val))
  end

  # Range operators
  defp apply_op(query, field, :sl, value) do
    where(query, [r], fragment("? << ?", field(r, ^field), ^value))
  end

  defp apply_op(query, field, :sr, value) do
    where(query, [r], fragment("? >> ?", field(r, ^field), ^value))
  end

  defp apply_op(query, field, :nxr, value) do
    where(query, [r], fragment("? &< ?", field(r, ^field), ^value))
  end

  defp apply_op(query, field, :nxl, value) do
    where(query, [r], fragment("? &> ?", field(r, ^field), ^value))
  end

  defp apply_op(query, field, :adj, value) do
    where(query, [r], fragment("? -|- ?", field(r, ^field), ^value))
  end

  # Full-text search — use to_tsvector with language config
  defp apply_op(query, field, :fts, {lang, value}) do
    where(
      query,
      [r],
      fragment("to_tsvector(?, ?) @@ to_tsquery(?, ?)", ^lang, field(r, ^field), ^lang, ^value)
    )
  end

  defp apply_op(query, field, :plfts, {lang, value}) do
    where(
      query,
      [r],
      fragment(
        "to_tsvector(?, ?) @@ plainto_tsquery(?, ?)",
        ^lang,
        field(r, ^field),
        ^lang,
        ^value
      )
    )
  end

  defp apply_op(query, field, :phfts, {lang, value}) do
    where(
      query,
      [r],
      fragment(
        "to_tsvector(?, ?) @@ phraseto_tsquery(?, ?)",
        ^lang,
        field(r, ^field),
        ^lang,
        ^value
      )
    )
  end

  defp apply_op(query, field, :wfts, {lang, value}) do
    where(
      query,
      [r],
      fragment(
        "to_tsvector(?, ?) @@ websearch_to_tsquery(?, ?)",
        ^lang,
        field(r, ^field),
        ^lang,
        ^value
      )
    )
  end

  # Helpers

  defp build_or_dynamic([first | rest]) do
    first_dynamic = build_dynamic(first)

    Enum.reduce(rest, first_dynamic, fn condition, acc ->
      condition_dynamic = build_dynamic(condition)
      dynamic([r], ^acc or ^condition_dynamic)
    end)
  end

  # Comparison
  defp build_dynamic(%{field: field, operator: :eq, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) == ^value)
  end

  defp build_dynamic(%{field: field, operator: :neq, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) != ^value)
  end

  defp build_dynamic(%{field: field, operator: :gt, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) > ^value)
  end

  defp build_dynamic(%{field: field, operator: :gte, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) >= ^value)
  end

  defp build_dynamic(%{field: field, operator: :lt, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) < ^value)
  end

  defp build_dynamic(%{field: field, operator: :lte, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) <= ^value)
  end

  # Pattern matching — no auto-wrap for ilike
  defp build_dynamic(%{field: field, operator: :like, value: value}) do
    field_atom = safe_to_atom(field)
    pattern = convert_wildcards(value)
    dynamic([r], like(field(r, ^field_atom), ^pattern))
  end

  defp build_dynamic(%{field: field, operator: :ilike, value: value}) do
    field_atom = safe_to_atom(field)
    pattern = convert_wildcards(value)
    dynamic([r], ilike(field(r, ^field_atom), ^pattern))
  end

  # POSIX regex
  defp build_dynamic(%{field: field, operator: :match, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? ~ ?", field(r, ^field_atom), ^value))
  end

  defp build_dynamic(%{field: field, operator: :imatch, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? ~* ?", field(r, ^field_atom), ^value))
  end

  # IN
  defp build_dynamic(%{field: field, operator: :in, value: values}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) in ^values)
  end

  # IS NULL
  defp build_dynamic(%{field: field, operator: :is_null, value: true}) do
    field_atom = safe_to_atom(field)
    dynamic([r], is_nil(field(r, ^field_atom)))
  end

  defp build_dynamic(%{field: field, operator: :is_null, value: false}) do
    field_atom = safe_to_atom(field)
    dynamic([r], not is_nil(field(r, ^field_atom)))
  end

  # IS boolean
  defp build_dynamic(%{field: field, operator: :is, value: val}) do
    field_atom = safe_to_atom(field)
    dynamic([r], field(r, ^field_atom) == ^val)
  end

  # IS DISTINCT FROM
  defp build_dynamic(%{field: field, operator: :isdistinct, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? IS DISTINCT FROM ?", field(r, ^field_atom), ^value))
  end

  # Array operators
  defp build_dynamic(%{field: field, operator: :cs, value: value}) do
    field_atom = safe_to_atom(field)
    array_val = parse_pg_array(value)
    dynamic([r], fragment("? @> ?", field(r, ^field_atom), ^array_val))
  end

  defp build_dynamic(%{field: field, operator: :cd, value: value}) do
    field_atom = safe_to_atom(field)
    array_val = parse_pg_array(value)
    dynamic([r], fragment("? <@ ?", field(r, ^field_atom), ^array_val))
  end

  defp build_dynamic(%{field: field, operator: :ov, value: value}) do
    field_atom = safe_to_atom(field)
    array_val = parse_pg_array(value)
    dynamic([r], fragment("? && ?", field(r, ^field_atom), ^array_val))
  end

  # Range operators
  defp build_dynamic(%{field: field, operator: :sl, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? << ?", field(r, ^field_atom), ^value))
  end

  defp build_dynamic(%{field: field, operator: :sr, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? >> ?", field(r, ^field_atom), ^value))
  end

  defp build_dynamic(%{field: field, operator: :nxr, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? &< ?", field(r, ^field_atom), ^value))
  end

  defp build_dynamic(%{field: field, operator: :nxl, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? &> ?", field(r, ^field_atom), ^value))
  end

  defp build_dynamic(%{field: field, operator: :adj, value: value}) do
    field_atom = safe_to_atom(field)
    dynamic([r], fragment("? -|- ?", field(r, ^field_atom), ^value))
  end

  # FTS
  defp build_dynamic(%{field: field, operator: :fts, value: {lang, value}}) do
    field_atom = safe_to_atom(field)

    dynamic(
      [r],
      fragment(
        "to_tsvector(?, ?) @@ to_tsquery(?, ?)",
        ^lang,
        field(r, ^field_atom),
        ^lang,
        ^value
      )
    )
  end

  defp build_dynamic(%{field: field, operator: :plfts, value: {lang, value}}) do
    field_atom = safe_to_atom(field)

    dynamic(
      [r],
      fragment(
        "to_tsvector(?, ?) @@ plainto_tsquery(?, ?)",
        ^lang,
        field(r, ^field_atom),
        ^lang,
        ^value
      )
    )
  end

  defp build_dynamic(%{field: field, operator: :phfts, value: {lang, value}}) do
    field_atom = safe_to_atom(field)

    dynamic(
      [r],
      fragment(
        "to_tsvector(?, ?) @@ phraseto_tsquery(?, ?)",
        ^lang,
        field(r, ^field_atom),
        ^lang,
        ^value
      )
    )
  end

  defp build_dynamic(%{field: field, operator: :wfts, value: {lang, value}}) do
    field_atom = safe_to_atom(field)

    dynamic(
      [r],
      fragment(
        "to_tsvector(?, ?) @@ websearch_to_tsquery(?, ?)",
        ^lang,
        field(r, ^field_atom),
        ^lang,
        ^value
      )
    )
  end

  defp convert_wildcards(value) do
    String.replace(value, "*", "%")
  end

  defp parse_pg_array(value) when is_binary(value) do
    value
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp parse_pg_array(value) when is_list(value), do: value
end
