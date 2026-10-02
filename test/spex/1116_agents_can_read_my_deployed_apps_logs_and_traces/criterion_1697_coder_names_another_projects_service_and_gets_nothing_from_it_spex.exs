defmodule CodeMySpecSpex.Story1116.Criterion1697Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1697 — Coder names another project's service and gets
  nothing from it.

  Rule 094d4f4b: an agent sees only its own project's logs and traces;
  nothing it passes can widen that.

  There is no `service`/`project` argument on `query_logs` — the only
  thing that decides which ClickHouse connection a call reaches is the
  calling project's own scope. This proves that side of it directly: no
  matter what text a caller searches for (even text naming another
  project's own service), the request still authenticates as *this*
  project's user. `stub_rows_for_username/2` would fail the test loudly
  the moment a request arrived under any other identity.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.ClickHouseCassetteHelpers
  alias CodeMySpec.McpServers.Observability.Tools.QueryLogs
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Naming another project's service widens nothing", criterion: 1697 do
    scenario "a coder searches for text naming another project's own service" do
      given_ "this project has telemetry configured, and a second project exists",
             context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)
        other_scope = Fixtures.other_project_scope(context.scope, "another-project")

        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, [
          %{"Timestamp" => "2026-10-02 08:00:00", "SeverityText" => "INFO", "Body" => "our own line"}
        ])

        {:ok, Map.put(context, :other_scope, other_scope)}
      end

      when_ "the coder searches for text naming the other project's service", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = QueryLogs.execute(%{text: "another-project-web"}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the request still reached only this project's own connection", context do
        refute context.reply.isError,
               "the request should still succeed against this project's own data: " <>
                 TaskResponseHelpers.response_text(context.reply)

        {:ok, context}
      end
    end
  end
end
