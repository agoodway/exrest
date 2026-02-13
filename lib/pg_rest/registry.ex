defmodule PgRest.Registry do
  @moduledoc """
  GenServer that discovers and indexes PgRest resources at startup.

  Uses ETS for concurrent read access — lookups don't serialize through the GenServer.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the registry GenServer.

  ## Options

    * `:otp_app` - application to scan for PgRest resources (auto-discovery)
    * `:modules` - explicit list of modules to register (skips discovery)
    * `:name` - GenServer name (default: `PgRest.Registry`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Looks up a resource by table name (string) or module (atom).
  """
  @spec get_resource(String.t() | module()) :: {:ok, map()} | {:error, :not_found}
  def get_resource(table_or_module) do
    case find_resource(table_or_module) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  @doc """
  Returns all registered resource configs.
  """
  @spec list_resources() :: [map()]
  def list_resources do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, config} -> config end)
    |> Enum.uniq_by(& &1.module)
  end

  @impl GenServer
  def init(opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    resources =
      case Keyword.get(opts, :modules) do
        nil ->
          otp_app = Keyword.fetch!(opts, :otp_app)
          discover_resources(otp_app)

        modules when is_list(modules) ->
          filter_resources(modules)
      end

    Enum.each(resources, fn config ->
      :ets.insert(table, {{:table, config.table}, config})
      :ets.insert(table, {{:module, config.module}, config})
    end)

    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp find_resource(table_name) when is_binary(table_name) do
    case :ets.lookup(@table, {:table, table_name}) do
      [{_key, config}] -> config
      [] -> nil
    end
  end

  defp find_resource(module) when is_atom(module) do
    case :ets.lookup(@table, {:module, module}) do
      [{_key, config}] -> config
      [] -> nil
    end
  end

  defp discover_resources(otp_app) do
    {:ok, modules} = :application.get_key(otp_app, :modules)
    filter_resources(modules)
  end

  defp filter_resources(modules) do
    modules
    |> Enum.filter(fn mod ->
      Code.ensure_loaded(mod)
      function_exported?(mod, :__pgrest_resource__, 0) and mod.__pgrest_resource__()
    end)
    |> Enum.map(fn mod -> mod.__pgrest_config__() end)
  end
end
