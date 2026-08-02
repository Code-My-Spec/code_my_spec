defmodule CodeMySpecSpex.Story966.Criterion8008Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8008 — A failed migration leaves the old version serving.

  When a migration fails partway, the deploy stops and the previously
  running version keeps serving traffic. The broken version never takes
  over. A failed migration that still swaps gives Sam an outage on top of
  a bad migration.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "kamal_deploy_migration_fails"

  @given_cassette "966_8008_version_serving"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :real_working_directory
  setup :connect_providers

  spex "A failed migration leaves the old version serving" do
    scenario "the deploy stops and the previous version is still live" do
      given_ "a version is deployed and serving", context do
        # A version genuinely deployed and serving, via the staged deploy (a
        # controllable bin/deploy stub + injected health probe) rather than a
        # real kamal run — the criterion is about what happens to *this* live
        # version when the next deploy fails, not about kamal.
        context = stage_deploy(context, :ok)
        view = mount_provisioning(context)

        view
        |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
        |> render_click()

        {:ok, context |> Map.put(:view, view)}
      end

      when_ "a deploy's migration fails partway", context do
        # The next deploy is set to fail; nothing else changes.
        stage_deploy(context, :migrate_fails)

        html =
          context.view
          |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the deploy stops", context do
        assert context.html =~ ~r/data-step="deploy"[^>]*data-state="errored"/,
               "expected the deploy step to stop on a failed migration"

        {:ok, context}
      end

      then_ "the broken version never took over", context do
        parsed = Floki.parse_document!(context.html)

        swap =
          parsed
          |> Floki.find("[data-test='deploy-phase'][data-phase='swap']")
          |> Floki.attribute("data-started-at")
          |> List.first()

        assert swap in [nil, ""],
               "expected the traffic swap never to have started, got #{inspect(swap)}"

        live_version =
          parsed
          |> Floki.find("[data-test='live-version']")
          |> Floki.attribute("data-role")
          |> List.first()

        # Anchor: something is still live — the environment did not go dark.
        assert live_version == "previous",
               "expected the previously running version to still be serving, got #{inspect(live_version)}"

        {:ok, context}
      end
    end
  end
end
