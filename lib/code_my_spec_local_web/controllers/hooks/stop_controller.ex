defmodule CodeMySpecLocalWeb.Hooks.StopController do
  @moduledoc """
  Handles the Stop hook event.

  Genuinely a thin HTTP layer now: it resolves scope from the request and hands
  the payload to `CodeMySpec.Hooks.Stop`, which owns the decision.

  The split follows what actually needs a machine. Running the analyzers needs
  this one — a working copy and a toolchain, reached through
  `CodeMySpec.Validation` further down the call. Deciding what their results
  mean needs only the database, and lives in `CodeMySpec.Hooks` so a laptop, a
  sprite and the server all reach the same verdict from the same inputs rather
  than each carrying a copy that drifts.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.Stop

  def handle(conn, params) do
    json(conn, Stop.decide(conn.assigns.current_scope, params))
  end
end
