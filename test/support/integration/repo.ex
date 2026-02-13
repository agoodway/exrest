defmodule PgRest.Integration.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :pg_rest, adapter: Ecto.Adapters.Postgres
end
