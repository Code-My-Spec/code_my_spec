defmodule CodeMySpecSpex.Story1081.Criterion1856Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1856 -- Shared-host projects stay isolated.

  Twin of criterion 1714.

  Surface: `CodeMySpec.Provisioning.Tools.QueryTelemetry`, driving
  `CodeMySpec.Telemetry`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
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

        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.merge(previous,
            run_probe: fn _opts -> {:ok, %{logs: 1, traces: 1}} end,
            query_probe: fn opts -> {:ok, %{project_id: Keyword.fetch!(opts, :project_id)}} end
          )
        )

        on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

        {:ok, servers_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(servers_view, :server)
        await_console_step(servers_view, :server)

        {:ok, view_a, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat"
          )

        run_console_step(view_a, :telemetry)
        await_console_step(view_a, :telemetry)

        {:ok, Map.put(context, :project_b, project_b)}
      end

      when_ "each project's agents query telemetry", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "query_telemetry",
            %{environment: "uat"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "each sees only its own project's logs and traces", context do
        assert match?({:ok, _}, context.response),
               "expected querying telemetry to succeed: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ context.project.id
        refute body =~ context.project_b.id

        {:ok, context}
      end
    end
  end
end
