defmodule CodeMySpecSpex.Story841.Criterion1966Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1966 — A missing secret fails the boot loudly and by name.

  Two claims, and the second is the one that matters. An app missing a secret
  must refuse to start rather than come up half-configured — and it must say
  *which* secret, because "boot failed" sends someone reading logs for the one
  variable nobody set.

  Surface: `ProvisioningLive`, running the deploy against an environment whose
  encrypted env file is short a required key.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "841_1966_missing_secret_refuses_boot"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A missing secret fails the boot loudly and by name" do
    scenario "the environment is short a required secret" do
      given_ "Sam is on the setup page and UAT is missing a required secret", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the deploy runs", context do
        html =
          with_full_cassette @cassette do
            context.view
            |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
            |> render_click()

            render(context.view)
          end

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the boot is refused rather than started half-configured", context do
        failure =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='boot-failure']")
          |> Floki.text()

        assert failure =~ "refuses to boot",
               "expected the app to refuse rather than start without its configuration, got: #{failure}"

        {:ok, context}
      end

      then_ "the missing secret is named", context do
        failure =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='boot-failure']")
          |> Floki.text()

        assert failure =~ "SECRET_KEY_BASE",
               "expected the missing key to be named so it can be set, got: #{failure}"

        {:ok, context}
      end
    end
  end
end
