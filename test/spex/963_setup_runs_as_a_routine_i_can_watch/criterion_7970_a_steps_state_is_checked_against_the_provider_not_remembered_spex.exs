defmodule CodeMySpecSpex.Story963.Criterion7970Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7970 — A step's state is checked against the provider, not remembered.

  Opening the status page re-checks each step against the provider rather
  than replaying the last run's result. Remembered state goes stale
  silently; checked state is what makes the page worth trusting and what
  makes drift visible.

  Observably: with the bucket long since created, opening the page issues
  the existence check — the cassette is recorded in `:replay` mode with a
  strict match, so a page that answered from memory without calling the
  provider would leave the cassette unplayed and fail.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @create_cassette "963_7970_hetzner_bucket_create_ok"
  @verify_cassette "hetzner_bucket_head_exists"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A step's state is checked against the provider, not remembered" do
    scenario "opening the page re-checks the bucket rather than trusting the old result" do
      given_ "the bucket step succeeded earlier", context do
        view = mount_provisioning(context)
        paste_storage_credentials(view)

        with_provider_cassette(@create_cassette, fn ->
          view
          |> element("[data-test='setup-step'][data-step='storage'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, context}
      end

      when_ "Sam opens the status page later", context do
        {view, html} =
          with_provider_cassette(@verify_cassette, fn ->
            {:ok, view, html} =
              live(context.conn, "/app/projects/#{context.project.id}/provisioning")

            {view, html}
          end)

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the step shows done on the strength of that check", context do
        assert context.html =~ ~r/data-step="storage"[^>]*data-state="done"/,
               "expected the storage step to read done after re-checking the provider"

        {:ok, context}
      end

      then_ "the page reports when it last verified, not when it last ran", context do
        assert has_element?(
                 context.view,
                 "[data-test='setup-step'][data-step='storage'][data-verified-at]"
               ),
               "expected the step to carry the time it was verified against the provider"

        {:ok, context}
      end
    end
  end
end
