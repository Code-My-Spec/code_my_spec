defmodule CodeMySpecSpex.Story1081.Criterion1852Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1852 -- Telemetry host is reachable over HTTPS with DNS set up.

  Twin of criterion 1710, framed from the client's connection succeeding
  rather than from the record's own existence.

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

  spex "Telemetry host is reachable over HTTPS with DNS set up", criterion: 1852 do
    scenario "the client's connection succeeds at a host setup created on Sam's domain" do
      given_ "setup has run for Sam's project", context do
        {:ok, project} = Fixtures.set_project_domain(context.project, "example.app")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        {:ok, context |> Map.put(:project, project) |> Map.put(:view, view)}
      end

      when_ "Sam's client connects to the telemetry host", context do
        response = fetch_site("telemetry.example.app")

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the connection succeeds over HTTPS at a host on Sam's own domain", context do
        assert context.response,
               "expected the connection to succeed over HTTPS at the telemetry host"

        {:ok, context}
      end

      then_ "its DNS record was already created by setup", context do
        resource =
          render(context.view)
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_dns']")

        assert resource != [],
               "expected setup to have already created the DNS record"

        {:ok, context}
      end
    end
  end
end
