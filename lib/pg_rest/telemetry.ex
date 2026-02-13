defmodule PgRest.Telemetry do
  @moduledoc """
  Telemetry events emitted by PgRest.

  PgRest uses `:telemetry.span/3` to instrument query pipeline operations.
  Each operation emits start, stop, and exception events.

  ## Events

  ### `[:pg_rest, :query, :start]`

  Emitted when a query pipeline operation begins.

  **Measurements:** `%{system_time: integer()}`

  **Metadata:**

    * `:resource` - the resource module being queried
    * `:operation` - one of `:read`, `:create`, `:update`, `:delete`,
      `:bulk_create`, `:bulk_update`, `:bulk_delete`, `:upsert`
    * `:repo` - the Ecto repo module

  ### `[:pg_rest, :query, :stop]`

  Emitted when a query pipeline operation completes successfully.

  **Measurements:** `%{duration: integer()}`

  **Metadata:** same as start event.

  ### `[:pg_rest, :query, :exception]`

  Emitted when a query pipeline operation raises an exception.

  **Measurements:** `%{duration: integer()}`

  **Metadata:** start metadata plus:

    * `:kind` - the exception kind (`:error`, `:exit`, `:throw`)
    * `:reason` - the exception or thrown value
    * `:stacktrace` - the stacktrace
  """
end
