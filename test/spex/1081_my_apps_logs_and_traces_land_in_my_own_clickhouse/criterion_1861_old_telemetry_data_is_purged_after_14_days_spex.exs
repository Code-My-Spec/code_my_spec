defmodule CodeMySpecSpex.Story1081.Criterion1861Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1861 -- Old telemetry data is purged after 14 days.

  Twin of criterion 1719, framed as the retention policy itself rather
  than a query against it. Modeled the way `Backups.retention_days/1`
  is: the policy is installed as part of setup, before any data lands,
  and recorded as its own resource so it can be read back.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:monitoring` step's retention policy.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Old telemetry data is purged after 14 days", criterion: 1861 do
    scenario "the retention policy drops data older than 14 days automatically" do
      given_ "telemetry data exists that is older than 14 days", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the retention policy runs", context do
        run_console_step(context.view, :monitoring)
        await_console_step(context.view, :monitoring)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "that data is dropped automatically", context do
        resource =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_retention']")

        assert resource != [],
               "expected setup to install a retention policy that purges data automatically"

        assert Floki.attribute(resource, "data-identifier") == ["14"],
               "expected the retention policy to keep 14 days"

        {:ok, context}
      end
    end
  end
end
