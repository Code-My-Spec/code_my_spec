defmodule CodeMySpecSpex.Story966.Criterion8009Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8009 — An unhealthy deploy does not become the live version.

  A new version that boots but fails its health check does not get the
  traffic. Sam's site stays served by the version that was working.

  Note the trap this criterion guards, from our own runbook: the proxy's
  health probe hits the app port directly over plain HTTP with no
  forwarded-proto header, so an app using `force_ssl` without excluding
  the health path 301s the probe and fails a deploy that was otherwise
  fine. Either way the correct outcome is the same — the working version
  keeps serving.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_working_directory
  setup :fake_providers

  spex "An unhealthy deploy does not become the live version" do
    scenario "a version failing its health check is not swapped in" do
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

      when_ "a new version boots but fails its health check", context do
        # The next deploy is set to fail; nothing else changes.
        stage_deploy(context, :health_fails)

        html =
          context.view
          |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the swap does not happen", context do
        parsed = Floki.parse_document!(context.html)

        swap_state =
          parsed
          |> Floki.find("[data-test='deploy-phase'][data-phase='swap']")
          |> Floki.attribute("data-state")
          |> List.first()

        refute swap_state == "done",
               "expected the traffic swap not to complete for an unhealthy version"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "Sam's site is still served by the version that was working", context do
        live_version =
          context.parsed
          |> Floki.find("[data-test='live-version']")
          |> Floki.attribute("data-role")
          |> List.first()

        assert live_version == "previous",
               "expected the working version to remain live, got #{inspect(live_version)}"

        {:ok, context}
      end

      then_ "the health check failure is reported rather than swallowed", context do
        text =
          context.parsed
          |> Floki.find("[data-test='deploy-failure']")
          |> Floki.text()

        assert text =~ ~r/health/i,
               "expected the failure to name the health check as the reason, got: #{inspect(text)}"

        {:ok, context}
      end
    end
  end
end
