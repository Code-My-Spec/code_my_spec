defmodule CodeMySpecSpex.Story1086.Criterion1764Spex do
  @moduledoc """
  Story 1086 — I see every change made to my project's setup
  Criterion 1764 — Sam's secret write shows the name, not the value.

  A log that leaked secret values would be worse than no log: it would
  turn Activity itself into the place a secret is easiest to find. The
  summary `ConsoleLive`'s `put_secret` handler builds names the key —
  `Steps.put_secret/4`'s own return value — and the submitted value never
  touches `Activity.record/5` at all.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Activity`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_working_directory
  setup :fake_providers
  setup :account_access_key

  spex "Sam's secret write shows the name, not the value", criterion: 1764 do
    scenario "writing STRIPE_KEY to uat" do
      given_ "uat's age key exists to encrypt into", context do
        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        run_console_step(repository_view, :repository)

        {:ok, servers_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/servers?env=uat"
          )

        run_console_step(servers_view, :secrets)

        {:ok, context}
      end

      when_ "Sam writes STRIPE_KEY into uat", context do
        {:ok, secrets_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/secrets")

        secrets_view
        |> form("[data-test='secret-form']", %{
          "secret" => %{
            "environment" => "uat",
            "key" => "STRIPE_KEY",
            "value" => "sk_live_super_secret"
          }
        })
        |> render_submit()

        {:ok, context}
      end

      then_ "Activity names the key and never the value", context do
        {:ok, activity_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/activity")

        html = render(activity_view)
        document = Floki.parse_document!(html)

        entries = Floki.find(document, "[data-test='activity-entry'][data-kind='secret_write']")

        assert entries != [], "the secret write never reached Activity"

        assert Floki.text(entries) =~ "STRIPE_KEY",
               "the entry does not name which secret was written"

        refute html =~ "sk_live_super_secret",
               "the secret's value leaked into the page that is supposed to show only its name"

        {:ok, context}
      end
    end
  end
end
