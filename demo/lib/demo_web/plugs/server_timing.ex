defmodule DemoWeb.Plugs.ServerTiming do
  @moduledoc """
  Adds a `Server-Timing` response header with total request duration.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    start = System.monotonic_time(:microsecond)

    register_before_send(conn, fn conn ->
      dur = (System.monotonic_time(:microsecond) - start) / 1000

      put_resp_header(
        conn,
        "server-timing",
        "total;dur=#{:erlang.float_to_binary(dur, decimals: 1)}"
      )
    end)
  end
end
