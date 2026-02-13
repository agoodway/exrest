ExUnit.start()

{:ok, _} = PgRest.Integration.Repo.start_link()

# Programmatic migration for test-only schemas (no priv/migrations needed)
Ecto.Migrator.up(PgRest.Integration.Repo, 1, PgRest.Integration.Migration)

Ecto.Adapters.SQL.Sandbox.mode(PgRest.Integration.Repo, :manual)
