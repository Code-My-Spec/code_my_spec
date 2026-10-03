defmodule CodeMySpecSpex.Story1081.Criterion1710Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1710 -- Sam's telemetry host answers over HTTPS.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:monitoring` step's DNS publication and TLS reachability.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Sam's telemetry host answers over HTTPS", criterion: 1710 do
    scenario "the telemetry host has a DNS record and a working certificate" do
      given_ "Sam's domain is example.app", context do
        {:ok, project} = Fixtures.set_project_domain(context.project, "example.app")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{project.id}/console/resources/servers?env=uat")

        {:ok, context |> Map.put(:project, project) |> Map.put(:view, view)}
      end

      when_ "telemetry setup for UAT completes", context do
        run_console_step(context.view, :monitoring)
        await_console_step(context.view, :monitoring)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "a telemetry host under example.app has a DNS record pointing at the UAT server",
            context do
        resource =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_dns']")

        assert resource != [],
               "expected the monitoring step to publish a DNS record for the telemetry host"

        {:ok, context}
      end

      then_ "it answers over HTTPS", context do
        response = fetch_site("telemetry.example.app")

        assert response, "expected the telemetry host to answer over HTTPS"

        {:ok, context}
      end
    end
  end
end
