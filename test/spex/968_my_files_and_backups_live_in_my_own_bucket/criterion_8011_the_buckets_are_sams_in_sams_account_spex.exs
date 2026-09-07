defmodule CodeMySpecSpex.Story968.Criterion8011Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8011 — The buckets are Sam's, in Sam's account.

  Object storage is provisioned into Sam's own Hetzner account. Nothing of
  his is held in platform-owned storage — his uploads and his database
  dumps are his, and stay his if he stops paying us.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Hetzner`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "The buckets are Sam's, in Sam's account" do
    scenario "the created buckets are recorded under Sam's own account" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        paste_storage_credentials(view)
        tear_down_after(context.scope, [:storage])

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the storage step has run", context do
        CodeMySpecSpex.Case.run_step_interaction(context.view, :storage, "prod")

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the buckets are under his own account", context do
        buckets =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='bucket']")

        # Anchor: buckets were recorded at all.
        assert buckets != [], "expected the storage step to record the buckets it created"

        for bucket <- buckets do
          owner = bucket |> Floki.attribute("data-owner") |> List.first()
          location = bucket |> Floki.attribute("data-location") |> List.first()

          assert owner == "user",
                 "expected each bucket to be owned by Sam, got #{inspect(owner)}"

          assert is_binary(location) and location != "",
                 "expected each bucket to record where it lives so Sam can find it in his console"
        end

        {:ok, context}
      end

      then_ "nothing of his sits in platform-owned storage", context do
        refute context.html =~ ~r/data-kind="bucket"[^>]*data-owner="platform"/,
               "expected no platform-owned bucket to hold Sam's data"

        {:ok, context}
      end
    end
  end
end
