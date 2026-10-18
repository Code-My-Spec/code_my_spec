defmodule CodeMySpecSpex.Story1116.Criterion1702Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1702 — Coder on a project without telemetry is told how to
  set it up.

  Rule f2136c8c: a project with no telemetry set up says so and points
  at the provisioning step, rather than surfacing an opaque connection
  error.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "No telemetry configured points at provisioning, not a stack trace", criterion: 1702 do
    scenario "a coder searches logs on a project nobody has set up telemetry for" do
      given_ "the project has never had telemetry provisioned", context do
        # given: already true — `setup :setup_active_project` creates a bare
        # project with no `ProjectSecrets` rows of any kind, and story 1081
        # (the only thing that would write
        # CLICKHOUSE_URL/USERNAME/PASSWORD) hasn't shipped.
        {:ok, context}
      end

      when_ "the coder searches its logs", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        reply = ToolLibrary.run("query_logs", %{}, %{scope: frame.assigns.current_scope})

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is told plainly that telemetry isn't set up, and where to fix that", context do
        assert match?({:error, _}, context.reply)
        text = TaskResponseHelpers.response_text(context.reply)
        assert text =~ "telemetry"
        assert text =~ "provisioning"

        {:ok, context}
      end
    end
  end
end
