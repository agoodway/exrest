defmodule PgRest.Authorization do
  @moduledoc """
  Behavior for pluggable authorization in PgRest.

  Implement this behavior to add runtime permission checks to your PgRest resources.

  ## Usage

      defmodule MyApp.PgRestAuth do
        @behaviour PgRest.Authorization

        @impl true
        def authorize(_conn, _resource_module, :read, _context), do: :ok
        def authorize(_conn, _resource_module, _op, %{role: :admin}), do: :ok
        def authorize(_conn, _resource_module, _op, _context), do: {:error, "Forbidden"}
      end

  Then configure in your router:

      forward "/api", PgRest.Plug,
        repo: MyApp.Repo,
        authorization: MyApp.PgRestAuth
  """

  @type operation :: :read | :create | :update | :delete

  @callback authorize(
              conn :: Plug.Conn.t(),
              resource_module :: module(),
              operation :: operation(),
              context :: map()
            ) :: :ok | {:error, String.t() | map()}
end
