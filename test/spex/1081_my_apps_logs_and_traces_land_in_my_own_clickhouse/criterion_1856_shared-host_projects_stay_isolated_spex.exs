defmodule CodeMySpecSpex.Story1081.Criterion1856Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1856 -- Shared-host projects stay isolated.

  Twin of criterion 1714.

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

  spex "Shared-host projects stay isolated", criterion: 1856 do
    scenario "each project's agents see only their own telemetry" do
      given_ "two projects share a telemetry host", context do
        project_b = Fixtures.project_fixture(context.scope, %{name: "project-b"})

        {:ok, view_a, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view_a, :monitoring)
        await_console_step(view_a, :monitoring)

        {:ok, Map.put(context, :project_b, project_b)}
      end

      when_ "each project's agents query telemetry", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = QueryTelemetry.execute(%{environment: "uat"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "each sees only its own project's logs and traces", context do
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
