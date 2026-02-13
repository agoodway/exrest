defmodule PgRest.Resource do
  @moduledoc """
  Behavior for defining PgRest API resources from Ecto schemas.

  ## Usage

      defmodule MyApp.Orders do
        use Ecto.Schema
        use PgRest.Resource

        schema "orders" do
          field :reference, :string
          field :status, :string
          timestamps()
        end

        import Ecto.Query

        @impl PgRest.Resource
        def scope(query, %{tenant_id: tid}) do
          where(query, [r], r.tenant_id == ^tid)
        end
      end
  """

  @typedoc "A map of contextual information (repo, user, tenant, etc.) passed to callbacks."
  @type context :: map()

  @doc "Applies scoping to the base query (e.g. tenant isolation)."
  @callback scope(Ecto.Query.t(), context()) :: Ecto.Query.t()

  @doc "Handles a custom query parameter not recognized by the standard parser."
  @callback handle_param(String.t(), String.t(), Ecto.Query.t(), context()) :: Ecto.Query.t()

  @doc "Builds a changeset for create and update operations."
  @callback changeset(Ecto.Schema.t(), map(), context()) :: Ecto.Changeset.t()

  @doc "Post-processes a record after loading from the database."
  @callback after_load(Ecto.Schema.t(), context()) :: Ecto.Schema.t()

  @valid_operations [:read, :create, :update, :delete]

  @doc "Injects PgRest resource behaviour, configuration, and default callback implementations."
  defmacro __using__(opts) do
    allow = validate_allow!(opts)

    quote do
      @behaviour PgRest.Resource
      @pgrest_resource true
      @pgrest_allow unquote(allow)

      @doc "Returns `true` to indicate this module is a PgRest resource."
      @spec __pgrest_resource__() :: true
      def __pgrest_resource__, do: true

      @doc "Returns the PgRest configuration map derived from the Ecto schema."
      @spec __pgrest_config__() :: map()
      def __pgrest_config__ do
        %{
          module: __MODULE__,
          table: __MODULE__.__schema__(:source),
          fields: __MODULE__.__schema__(:fields),
          associations: __MODULE__.__schema__(:associations),
          primary_key: __MODULE__.__schema__(:primary_key),
          allow: @pgrest_allow
        }
      end

      @doc "Applies scoping to the query. Override to add tenant isolation or other filters."
      @impl PgRest.Resource
      def scope(query, _context), do: query

      @doc "Handles custom query parameters. Override to support non-standard filters."
      @impl PgRest.Resource
      def handle_param(_key, _value, query, _context), do: query

      @doc "Builds a changeset for create/update operations. Override to add validations."
      @impl PgRest.Resource
      def changeset(struct, attrs, _context) do
        Ecto.Changeset.cast(struct, attrs, [])
      end

      @doc "Post-processes a loaded record. Override to transform data after retrieval."
      @impl PgRest.Resource
      def after_load(record, _context), do: record

      defoverridable scope: 2, handle_param: 4, changeset: 3, after_load: 2
    end
  end

  defp validate_allow!(opts) do
    case Keyword.get(opts, :allow, :all) do
      :all ->
        :all

      ops when is_list(ops) ->
        invalid = ops -- @valid_operations

        if invalid != [] do
          raise ArgumentError,
                "invalid operations in :allow option: #{inspect(invalid)}. " <>
                  "Valid operations are: #{inspect(@valid_operations)}"
        end

        if ops == [] do
          raise ArgumentError,
                ":allow option cannot be an empty list. " <>
                  "Valid operations are: #{inspect(@valid_operations)}"
        end

        ops

      other ->
        raise ArgumentError,
              "invalid :allow option: #{inspect(other)}. " <>
                "Expected :all or a list of operations from: #{inspect(@valid_operations)}"
    end
  end
end
