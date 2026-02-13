defmodule PgRest.Select do
  @moduledoc """
  Applies parsed select AST to Ecto queries.

  Supports:
  - Field selection on the root resource
  - Embed preloading with optional field selection
  - Embed filtering via preload queries
  - `!inner` joins for top-level filtering by associated data
  - Anti-joins via left join + is_nil check
  - Nested embeds (recursive preload structures)
  - Embed aliasing (renaming association keys in response)
  """

  import Ecto.Query
  import PgRest.Utils, only: [safe_to_atom: 1]

  @doc """
  Applies the parsed select AST to an Ecto query.

  Splits the AST into root-level field selections and embed preloads,
  then applies each to the query using Ecto's `select/3` and `preload/3`.
  """
  @spec apply_select(Ecto.Queryable.t(), [map()] | nil, module(), map(), map()) ::
          Ecto.Queryable.t() | Ecto.Query.t()
  def apply_select(query, select_ast, resource_module, embed_filters, embed_options \\ %{})

  def apply_select(query, nil, _resource_module, _embed_filters, _embed_options), do: query

  def apply_select(query, select_ast, resource_module, embed_filters, embed_options)
      when is_list(select_ast) do
    {fields, embeds} = split_fields_and_embeds(select_ast)

    query
    |> apply_field_select(fields, embeds, resource_module)
    |> apply_embeds(embeds, resource_module, embed_filters, embed_options)
  end

  # --- Field Selection ---

  defp apply_field_select(query, [], _embeds, _resource_module), do: query

  # Applies `select(query, struct(r, fields))` to restrict returned columns.
  # Auto-includes PK and FK fields required for Ecto preloads.
  # When `*` is present in the field list, all columns are selected (no restriction).
  defp apply_field_select(query, fields, embeds, resource_module) do
    if Enum.any?(fields, &(&1.name == "*")) do
      query
    else
      field_atoms = Enum.map(fields, &safe_to_atom(&1.name))

      all_fields =
        field_atoms
        |> Kernel.++(required_root_keys(resource_module, embeds))
        |> Enum.uniq()

      select(query, [r], struct(r, ^all_fields))
    end
  end

  defp required_root_keys(_resource_module, []), do: []

  defp required_root_keys(resource_module, embeds) do
    pk = resource_module.__schema__(:primary_key)

    fks =
      Enum.flat_map(embeds, fn embed ->
        assoc_name = resolve_assoc_name(resource_module, embed.name)

        case resource_module.__schema__(:association, assoc_name) do
          %{owner_key: owner_key} -> [owner_key]
          _ -> []
        end
      end)

    Enum.uniq(pk ++ fks)
  end

  # --- Embed Application ---

  defp apply_embeds(query, [], _resource_module, _embed_filters, _embed_options), do: query

  defp apply_embeds(query, embeds, resource_module, embed_filters, embed_options) do
    needs_distinct? = Enum.any?(embeds, &requires_join?(&1, embed_filters))

    query =
      Enum.reduce(embeds, query, fn embed, acc ->
        apply_single_embed(acc, embed, resource_module, embed_filters, embed_options)
      end)

    if needs_distinct?, do: distinct(query, true), else: query
  end

  # Checks whether an embed will produce a join (requiring DISTINCT).
  defp requires_join?(embed, embed_filters) do
    filters = Map.get(embed_filters, embed.name, [])

    case detect_anti_join(filters) do
      {:anti_join, _} -> true
      :not_anti_join -> Map.get(embed, :inner, false)
    end
  end

  # Routes a single embed to the appropriate handler based on its filters
  # and join mode (`!inner`, anti-join, or standard preload).
  # Uses schema reflection to resolve the association atom, which also
  # ensures the schema module is loaded before any atom conversion.
  defp apply_single_embed(query, embed, resource_module, embed_filters, embed_options) do
    assoc_name = resolve_assoc_name(resource_module, embed.name)
    filters = Map.get(embed_filters, embed.name, [])
    options = Map.get(embed_options, embed.name, %{})
    inner? = Map.get(embed, :inner, false)

    case detect_anti_join(filters) do
      {:anti_join, :null} ->
        apply_anti_join(query, assoc_name, resource_module)

      {:anti_join, :not_null} ->
        apply_existence_join(query, assoc_name, resource_module)

      :not_anti_join ->
        if inner? do
          query
          |> apply_inner_join(assoc_name, resource_module, filters)
          |> apply_preload_with_options(
            assoc_name,
            embed,
            resource_module,
            filters,
            options,
            embed_filters
          )
        else
          apply_preload_with_options(
            query,
            assoc_name,
            embed,
            resource_module,
            filters,
            options,
            embed_filters
          )
        end
    end
  end

  # --- Anti-Join Detection ---

  # Checks if the embed filters represent an anti-join pattern:
  # `assoc=is.null` (null) or `assoc=not.is.null` (not_null).
  defp detect_anti_join(filters) do
    case filters do
      [%{field: :__embed_exists__, operator: :is_null, value: true}] -> {:anti_join, :null}
      [%{field: :__embed_exists__, operator: :is_null, value: false}] -> {:anti_join, :not_null}
      _ -> :not_anti_join
    end
  end

  # --- Anti-Join (LEFT JOIN + IS NULL) ---

  # Returns parent rows that have NO matching children.
  # Performs: LEFT JOIN assoc ON ... WHERE assoc.pk IS NULL
  # Only works for has_many/belongs_to; many_to_many falls through.
  defp apply_anti_join(query, assoc_name, resource_module) do
    case get_join_info(resource_module, assoc_name) do
      nil ->
        raise ArgumentError,
              "anti-join (is.null) not supported for many_to_many association " <>
                ":#{assoc_name}. Use preload-only syntax instead."

      {related_module, related_key, owner_key} ->
        query
        |> join(:left, [r], a in ^related_module,
          on: field(a, ^related_key) == field(r, ^owner_key),
          as: ^assoc_name
        )
        |> where([{^assoc_name, a}], is_nil(field(a, ^get_pk(related_module))))
    end
  end

  # --- Existence Join (INNER JOIN + DISTINCT) ---

  # Returns parent rows that have at least one matching child.
  # Equivalent to `!inner` with no field-level filters.
  defp apply_existence_join(query, assoc_name, resource_module) do
    case get_join_info(resource_module, assoc_name) do
      nil ->
        raise ArgumentError,
              "existence join (not.is.null) not supported for many_to_many association " <>
                ":#{assoc_name}. Use preload-only syntax instead."

      {related_module, related_key, owner_key} ->
        join(query, :inner, [r], a in ^related_module,
          on: field(a, ^related_key) == field(r, ^owner_key),
          as: ^assoc_name
        )
    end
  end

  # --- Inner Join (!inner modifier) ---

  # Applies an inner join on the association, optionally with WHERE filters
  # on the joined table. Uses named bindings and DISTINCT to avoid duplicates.
  # Only works for has_many/belongs_to; many_to_many is handled via preload only.
  defp apply_inner_join(query, assoc_name, resource_module, filters) do
    case get_join_info(resource_module, assoc_name) do
      nil ->
        raise ArgumentError,
              "!inner join not supported for many_to_many association " <>
                ":#{assoc_name}. Use preload-only syntax instead."

      {related_module, related_key, owner_key} ->
        query
        |> join(:inner, [r], a in ^related_module,
          on: field(a, ^related_key) == field(r, ^owner_key),
          as: ^assoc_name
        )
        |> apply_join_filters(assoc_name, filters)
    end
  end

  # --- Join Filters ---

  defp apply_join_filters(query, _assoc_name, []), do: query

  # Applies WHERE clauses on the joined association binding.
  # Skips `__embed_exists__` sentinel filters (handled by anti-join detection).
  defp apply_join_filters(query, assoc_name, filters) do
    field_filters = Enum.reject(filters, &(&1.field == :__embed_exists__))

    Enum.reduce(field_filters, query, fn filter, acc ->
      apply_join_filter(acc, assoc_name, filter)
    end)
  end

  defp apply_join_filter(query, _name, %{field: :__embed_exists__}), do: query

  defp apply_join_filter(query, name, %{operator: :eq, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) == ^v))
  end

  defp apply_join_filter(query, name, %{operator: :neq, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) != ^v))
  end

  defp apply_join_filter(query, name, %{operator: :gt, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) > ^v))
  end

  defp apply_join_filter(query, name, %{operator: :gte, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) >= ^v))
  end

  defp apply_join_filter(query, name, %{operator: :lt, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) < ^v))
  end

  defp apply_join_filter(query, name, %{operator: :lte, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) <= ^v))
  end

  defp apply_join_filter(query, name, %{operator: :like, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], like(field(a, ^f), ^v)))
  end

  defp apply_join_filter(query, name, %{operator: :ilike, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], ilike(field(a, ^f), ^v)))
  end

  defp apply_join_filter(query, name, %{operator: :in, field: f, value: v}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], field(a, ^f) in ^v))
  end

  defp apply_join_filter(query, name, %{operator: :is_null, field: f, value: true}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], is_nil(field(a, ^f))))
  end

  defp apply_join_filter(query, name, %{operator: :is_null, field: f, value: false}) do
    f = safe_to_atom(f)
    where(query, ^dynamic([{^name, a}], not is_nil(field(a, ^f))))
  end

  defp apply_join_filter(query, _name, _filter), do: query

  # --- Preload with Options ---

  # Builds the appropriate preload for an embed based on its field selection,
  # filters, and nested embeds. Falls back to simple preload when no
  # customization is needed.
  defp apply_preload_with_options(
         query,
         assoc_name,
         embed,
         resource_module,
         filters,
         options,
         embed_filters
       ) do
    field_filters = Enum.reject(filters, &(&1.field == :__embed_exists__))
    embed_fields = Map.get(embed, :fields, [])
    nested_embeds = extract_nested_embeds(embed_fields)
    plain_fields = extract_plain_fields(embed_fields)

    needs_query? =
      field_filters != [] or (plain_fields != [] and plain_fields != ["*"]) or
        nested_embeds != [] or options != %{}

    if needs_query? do
      nested_filters = nested_embed_filters(embed.name, embed_filters)

      preload_query =
        build_preload_query(
          assoc_name,
          resource_module,
          plain_fields,
          field_filters,
          nested_embeds,
          options,
          nested_filters
        )

      preload(query, [{^assoc_name, ^preload_query}])
    else
      preload(query, ^[assoc_name])
    end
  end

  # Builds a preload sub-query with optional field selection, filters,
  # ordering, limit/offset, and nested preloads for deeper embed levels.
  defp build_preload_query(
         assoc_name,
         resource_module,
         plain_fields,
         filters,
         nested_embeds,
         options,
         nested_embed_filters
       ) do
    related_module = get_related_module(resource_module, assoc_name)

    from(r in related_module)
    |> maybe_select_fields(plain_fields, resource_module, assoc_name)
    |> apply_preload_filters(filters)
    |> apply_embed_order(Map.get(options, :order))
    |> apply_embed_limit(Map.get(options, :limit))
    |> apply_embed_offset(Map.get(options, :offset))
    |> apply_nested_preloads(nested_embeds, related_module, nested_embed_filters)
  end

  # --- Embed Ordering & Pagination ---

  defp apply_embed_order(query, nil), do: query

  defp apply_embed_order(query, directives) do
    PgRest.Order.apply_order(query, directives)
  end

  defp apply_embed_limit(query, nil), do: query

  defp apply_embed_limit(query, limit) when is_integer(limit) do
    limit(query, ^limit)
  end

  defp apply_embed_offset(query, nil), do: query

  defp apply_embed_offset(query, offset) when is_integer(offset) do
    offset(query, ^offset)
  end

  # --- Preload Field Selection ---

  defp maybe_select_fields(query, [], _resource_module, _assoc_name), do: query
  defp maybe_select_fields(query, ["*"], _resource_module, _assoc_name), do: query

  # Restricts the preloaded association to only the specified columns.
  # Auto-includes PK and FK fields required for Ecto to map children to parents.
  defp maybe_select_fields(query, fields, resource_module, assoc_name) do
    field_atoms = Enum.map(fields, &safe_to_atom/1)

    all_fields =
      field_atoms
      |> Kernel.++(required_preload_keys(resource_module, assoc_name))
      |> Enum.uniq()

    select(query, [r], struct(r, ^all_fields))
  end

  defp required_preload_keys(resource_module, assoc_name) do
    case resource_module.__schema__(:association, assoc_name) do
      %Ecto.Association.Has{related_key: fk, related: related} ->
        [fk | related.__schema__(:primary_key)] |> Enum.uniq()

      %Ecto.Association.BelongsTo{related: related} ->
        related.__schema__(:primary_key)

      _ ->
        []
    end
  end

  # --- Preload Filters ---

  defp apply_preload_filters(query, []), do: query

  # Applies WHERE clauses to a preload sub-query, filtering which
  # associated records are loaded.
  defp apply_preload_filters(query, filters) do
    Enum.reduce(filters, query, fn filter, acc ->
      apply_preload_filter(acc, filter)
    end)
  end

  defp apply_preload_filter(query, filter) do
    case build_filter_dynamic(filter) do
      nil -> query
      dynamic -> where(query, [_], ^dynamic)
    end
  end

  # Builds an Ecto dynamic expression for a filter.
  # Returns nil for unsupported operators.
  defp build_filter_dynamic(%{operator: :eq} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) == ^f.value)

  defp build_filter_dynamic(%{operator: :neq} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) != ^f.value)

  defp build_filter_dynamic(%{operator: :gt} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) > ^f.value)

  defp build_filter_dynamic(%{operator: :gte} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) >= ^f.value)

  defp build_filter_dynamic(%{operator: :lt} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) < ^f.value)

  defp build_filter_dynamic(%{operator: :lte} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) <= ^f.value)

  defp build_filter_dynamic(%{operator: :like} = f),
    do: dynamic([r], like(field(r, ^safe_to_atom(f.field)), ^f.value))

  defp build_filter_dynamic(%{operator: :ilike} = f),
    do: dynamic([r], ilike(field(r, ^safe_to_atom(f.field)), ^f.value))

  defp build_filter_dynamic(%{operator: :in} = f),
    do: dynamic([r], field(r, ^safe_to_atom(f.field)) in ^f.value)

  defp build_filter_dynamic(%{operator: :is_null, value: true} = f),
    do: dynamic([r], is_nil(field(r, ^safe_to_atom(f.field))))

  defp build_filter_dynamic(%{operator: :is_null, value: false} = f),
    do: dynamic([r], not is_nil(field(r, ^safe_to_atom(f.field))))

  defp build_filter_dynamic(_), do: nil

  # --- Nested Preloads ---

  defp apply_nested_preloads(query, [], _resource_module, _embed_filters), do: query

  # Recursively builds preload structures for nested embeds.
  # Each nested embed becomes either a simple atom preload (all fields)
  # or a `{assoc_name, sub_query}` tuple with field selection and/or filters.
  defp apply_nested_preloads(query, nested_embeds, resource_module, embed_filters) do
    preloads =
      Enum.map(nested_embeds, fn nested ->
        build_nested_preload(nested, resource_module, embed_filters)
      end)

    preload(query, ^preloads)
  end

  # Builds a single nested preload entry.
  defp build_nested_preload(nested, resource_module, embed_filters) do
    nested_name = safe_to_atom(nested.name)
    nested_fields = Map.get(nested, :fields, [])
    nested_plain = extract_plain_fields(nested_fields)
    deeper_nested = extract_nested_embeds(nested_fields)
    direct_filters = Map.get(embed_filters, nested.name, [])

    if (nested_plain == [] or nested_plain == ["*"]) and deeper_nested == [] and
         direct_filters == [] do
      nested_name
    else
      sub_embed_filters = nested_embed_filters(nested.name, embed_filters)

      sub_query =
        build_nested_sub_query(
          nested_name,
          resource_module,
          nested_plain,
          deeper_nested,
          direct_filters,
          sub_embed_filters
        )

      {nested_name, sub_query}
    end
  end

  # Builds a sub-query for nested preloads with optional field selection,
  # filters, and deeper nesting levels.
  defp build_nested_sub_query(
         assoc_name,
         resource_module,
         plain_fields,
         deeper_nested,
         filters,
         embed_filters
       ) do
    related_module = get_related_module(resource_module, assoc_name)

    from(r in related_module)
    |> maybe_select_fields(plain_fields, resource_module, assoc_name)
    |> apply_preload_filters(filters)
    |> apply_nested_preloads(deeper_nested, related_module, embed_filters)
  end

  # --- Helpers ---

  # Extracts embed_filters relevant to a nested embed by stripping the prefix.
  # e.g., for assoc "posts", key "posts.comments" becomes "comments"
  defp nested_embed_filters(assoc_name, embed_filters) when is_binary(assoc_name) do
    prefix = assoc_name <> "."

    embed_filters
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
    |> Enum.map(fn {key, filters} -> {String.trim_leading(key, prefix), filters} end)
    |> Map.new()
  end

  defp extract_nested_embeds(fields) do
    Enum.filter(fields, &match?(%{type: :embed}, &1))
  end

  defp extract_plain_fields(fields) do
    Enum.filter(fields, &is_binary/1)
  end

  defp split_fields_and_embeds(select_ast) do
    Enum.split_with(select_ast, fn item -> item.type == :field end)
  end

  # Extracts join info for has_many/belongs_to associations.
  # Returns `{related_module, related_key, owner_key}` or `nil` for
  # many_to_many (which requires join-table based joins not yet supported).
  defp get_join_info(resource_module, assoc_name) do
    case get_assoc_info(resource_module, assoc_name) do
      %{related_key: related_key, owner_key: owner_key} = info ->
        {info.related, related_key, owner_key}

      _ ->
        nil
    end
  end

  # Resolves a string association name to its atom equivalent by looking it
  # up in the schema's association list. This triggers module loading, ensuring
  # all schema atoms are registered before any `to_existing_atom` calls.
  defp resolve_assoc_name(resource_module, name_str) when is_binary(name_str) do
    assocs = resource_module.__schema__(:associations)

    Enum.find(assocs, fn assoc_atom ->
      Atom.to_string(assoc_atom) == name_str
    end) ||
      raise ArgumentError,
            "unknown association #{inspect(name_str)} on #{inspect(resource_module)}. " <>
              "Available: #{inspect(assocs)}"
  end

  defp resolve_assoc_name(_resource_module, name) when is_atom(name), do: name

  # Returns the related module for an association, or raises if not found.
  defp get_related_module(resource_module, assoc_name) do
    case get_assoc_info(resource_module, assoc_name) do
      nil ->
        available = resource_module.__schema__(:associations)

        raise ArgumentError,
              "unknown association #{inspect(assoc_name)} on #{inspect(resource_module)}. " <>
                "Available: #{inspect(available)}"

      assoc_info ->
        assoc_info.related
    end
  end

  defp get_assoc_info(nil, _assoc_name), do: nil

  defp get_assoc_info(resource_module, assoc_name) do
    resource_module.__schema__(:association, assoc_name)
  rescue
    _ -> nil
  end

  defp get_pk(module) do
    case module.__schema__(:primary_key) do
      [pk] -> pk
      _ -> :id
    end
  rescue
    _ -> :id
  end
end
