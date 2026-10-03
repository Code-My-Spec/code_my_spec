defmodule CodeMySpecSpex.Story1081.Criterion1714Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1714 -- Two projects share a box and stay separate.

  The reading agent drives this, not Sam at a browser, so the surface is
  the MCP tool an agent actually calls rather than the console.

  Surface: `CodeMySpec.McpServers.Devops.Tools.QueryTelemetry`, driving
  `CodeMySpec.Telemetry`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.QueryTelemetry
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Two projects share a box and stay separate", criterion: 1714 do
    scenario "the first project's agent sees only its own project's telemetry" do
      given_ "Sam's two projects deploy to the same UAT server, both with telemetry", context do
        project_b = Fixtures.project_fixture(context.scope, %{name: "project-b"})

        {:ok, view_a, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view_a, :monitoring)
        await_console_step(view_a, :monitoring)

        {:ok, Map.put(context, :project_b, project_b)}
      end

      when_ "the first project's agent reads UAT telemetry", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = QueryTelemetry.execute(%{environment: "uat"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it sees only the first project's logs and traces", context do
        refute context.response.isError,
               "expected querying telemetry to succeed: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ context.project.name
        refute body =~ context.project_b.name

        {:ok, context}
      end
    end
  end
end
