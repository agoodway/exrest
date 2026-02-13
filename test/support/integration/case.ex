defmodule PgRest.Integration.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias PgRest.Integration.{E2EProduct, E2EReview, Repo, Router}
  alias Supabase.PostgREST

  using do
    quote do
      import PgRest.Integration.Case, only: [supabase_from: 2]
    end
  end

  setup do
    # Checkout a shared sandbox connection so Bandit workers share it
    pid = Sandbox.start_owner!(Repo, shared: true)

    # Start Registry with our integration schemas
    registry =
      start_supervised!({PgRest.Registry, modules: [E2EProduct, E2EReview]})

    # Start Bandit on a random port
    bandit =
      start_supervised!({Bandit, plug: Router, port: 0, ip: :loopback})

    # Get the assigned port
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    base_url = "http://localhost:#{port}"

    # Initialize Supabase client
    {:ok, client} =
      Supabase.init_client(base_url, "test-api-key", db: [schema: "public"])

    on_exit(fn ->
      Sandbox.stop_owner(pid)
    end)

    %{client: client, base_url: base_url, port: port, registry: registry}
  end

  @doc "Convenience wrapper for Supabase.PostgREST.from/2"
  def supabase_from(client, table) do
    PostgREST.from(client, table)
  end
end
