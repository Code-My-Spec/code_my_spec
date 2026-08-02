defmodule CodeMySpecSpex.Story966.Criterion8007Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8007 — Migrations land before the swap, not after.

  A deploy carrying a schema change runs the migration against the new
  image *before* traffic moves, and serves requests throughout. Migrating
  after the swap means every request in the gap hits new code against an
  old schema — which is the "every request 500s right after a successful
  deploy" failure in our own runbook.

  The ordering is the assertion: this spec compares recorded timestamps
  rather than merely checking both happened.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "kamal_deploy_migrate_then_swap"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :real_working_directory
  setup :connect_providers

  spex "Migrations land before the swap, not after" do
    scenario "the migration completes before traffic moves to the new version" do
      given_ "a deploy carries a schema change", context do
        context = stage_deploy(context, :ok)
        view = mount_provisioning(context)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the deploy runs", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the migration completed before the traffic swap", context do
        parsed = Floki.parse_document!(context.html)

        migrate_at =
          parsed
          |> Floki.find("[data-test='deploy-phase'][data-phase='migrate']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        swap_at =
          parsed
          |> Floki.find("[data-test='deploy-phase'][data-phase='swap']")
          |> Floki.attribute("data-started-at")
          |> List.first()

        # Anchor: both phases were recorded, so the comparison is real.
        assert is_binary(migrate_at) and migrate_at != "",
               "expected the deploy to record when the migration completed"

        assert is_binary(swap_at) and swap_at != "",
               "expected the deploy to record when the traffic swap started"

        assert migrate_at <= swap_at,
               "expected the migration to finish before the swap began: migrate_at=#{migrate_at} swap_at=#{swap_at}"

        {:ok, context}
      end

      then_ "requests were served throughout", context do
        refute context.html =~ ~r/data-test="deploy-downtime"[^>]*data-observed="true"/,
               "expected no downtime window during a migrate-then-swap deploy"

        {:ok, context}
      end
    end
  end
end
