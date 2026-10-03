defmodule CodeMySpecSpex.Story1081.Criterion1711Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1711 -- Sam re-runs setup on a working stack.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:monitoring` step's idempotent re-run.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Sam re-runs setup on a working stack", criterion: 1711 do
    scenario "re-running keeps collected data and existing credentials" do
      given_ "UAT telemetry is set up and collecting", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        identifier =
          render(view)
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_credential']")
          |> Floki.attribute("data-identifier")
          |> List.first()

        {:ok, context |> Map.put(:view, view) |> Map.put(:identifier, identifier)}
      end

      when_ "Sam runs the telemetry setup step again", context do
        run_console_step(context.view, :monitoring)
        await_console_step(context.view, :monitoring)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "collected data is kept", context do
        assert resource_step_state?(context.html, "monitoring", "done"),
               "expected the re-run to leave the step done, not reset"

        {:ok, context}
      end

      then_ "existing credentials still work", context do
        identifier =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_credential']")
          |> Floki.attribute("data-identifier")
          |> List.first()

        assert identifier == context.identifier,
               "expected the re-run to keep the same credential rather than mint a new one"

        {:ok, context}
      end
    end
  end
end
