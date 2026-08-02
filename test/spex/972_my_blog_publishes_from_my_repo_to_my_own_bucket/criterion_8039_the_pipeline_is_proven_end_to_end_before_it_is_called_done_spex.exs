defmodule CodeMySpecSpex.Story972.Criterion8039Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8039 — The pipeline is proven end to end before it is called done.

  The publishing step does not report done on the strength of having written
  configuration. It publishes a real post, confirms it rendered on the
  deployed site, and only then marks itself finished — the same
  prove-it-before-claiming-it gate as the backup restore in 968 and the
  inbound delivery in 974.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "content_step_proves_render_before_done"

  @given_cassette "972_8039_site_deployed"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The pipeline is proven end to end before it is called done" do
    scenario "the step confirms a rendered post before reporting done" do
      # Renamed, and made true. The old title said the publishing step had
      # already configured everything, but the `when_` is that step running —
      # so the precondition described the thing under test. What it actually
      # needs is somewhere to publish *to*: a bucket and a deployed site, or
      # the render proof has nothing to fetch and the step fails for a reason
      # that has nothing to do with proving a render.
      given_ "Sam's site is deployed and his storage is ready", context do
        view = mount_provisioning(context)
        paste_storage_credentials(view)
        run_steps(view, [:repository, :server, :secrets, :domain, :dns, :deploy, :storage], @given_cassette)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='content'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it confirmed a real post rendered on the deployed site", context do
        parsed = Floki.parse_document!(context.html)

        proof = parsed |> Floki.find("[data-test='content-render-proof']")

        # Anchor: a proof exists rather than only a configuration summary.
        assert proof != [], "expected the content step to record a render proof"

        state = proof |> Floki.attribute("data-state") |> List.first()

        assert state == "rendered",
               "expected the proof to be an actual rendered post, got #{inspect(state)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the step marked done", context do
        assert context.html =~ ~r/data-step="content"[^>]*data-state="done"/,
               "expected the content step to be done once the render was proven"

        proven_at =
          context.parsed
          |> Floki.find("[data-test='content-render-proof']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='content']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(proven_at) and is_binary(done_at),
               "expected both the proof and the step completion to be timestamped"

        assert proven_at <= done_at,
               "expected the render proof to precede the step being called done: proven_at=#{proven_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
