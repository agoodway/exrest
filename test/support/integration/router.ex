defmodule PgRest.Integration.Router do
  @moduledoc false
  use Plug.Router

  plug(:ensure_query_params)
  plug(:match)
  plug(:dispatch)

  defp ensure_query_params(conn, _opts), do: Plug.Conn.fetch_query_params(conn)

  forward("/rest/v1", to: PgRest.Plug, init_opts: [repo: PgRest.Integration.Repo])

  match _ do
    send_resp(conn, 404, "not found")
  end
end
