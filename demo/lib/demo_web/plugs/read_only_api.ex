defmodule DemoWeb.Plugs.ReadOnlyApi do
  @moduledoc """
  Blocks non-GET requests on the demo API to prevent mutations.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(405, Jason.encode!(%{error: "Method not allowed. This demo API is read-only."}))
    |> halt()
  end
end
