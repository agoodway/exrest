defmodule PgRest.Order do
  @moduledoc """
  Applies parsed order directives to Ecto queries.
  """

  import Ecto.Query
  import PgRest.Utils, only: [safe_to_atom: 1]

  @doc """
  Applies parsed order directives to an Ecto query.

  Supports `:asc`/`:desc` directions with optional `:nulls_first`/`:nulls_last`.
  """
  @spec apply_order(Ecto.Queryable.t(), [map()] | nil) :: Ecto.Queryable.t() | Ecto.Query.t()
  def apply_order(query, nil), do: query

  def apply_order(query, directives) when is_list(directives) do
    Enum.reduce(directives, query, &apply_directive/2)
  end

  defp apply_directive(%{field: field, direction: direction, nulls: nulls}, query) do
    field_atom = safe_to_atom(field)

    case {direction, nulls} do
      {:asc, nil} ->
        order_by(query, [r], asc: field(r, ^field_atom))

      {:desc, nil} ->
        order_by(query, [r], desc: field(r, ^field_atom))

      {:asc, :first} ->
        order_by(query, [r], asc_nulls_first: field(r, ^field_atom))

      {:asc, :last} ->
        order_by(query, [r], asc_nulls_last: field(r, ^field_atom))

      {:desc, :first} ->
        order_by(query, [r], desc_nulls_first: field(r, ^field_atom))

      {:desc, :last} ->
        order_by(query, [r], desc_nulls_last: field(r, ^field_atom))
    end
  end
end
