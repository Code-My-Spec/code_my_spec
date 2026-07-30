defmodule CodeMySpecSpex.Story973.Criterion8044Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8044 — The widget is proven by a message, not by a script tag.

  The widget step confirms a real message travelled from the deployed site
  into CodeMySpec before reporting done. Asserting the script tag is present
  proves the generator ran, not that feedback works — and the failure would
  only surface when a visitor's message vanished.

  Same prove-it-before-claiming-it gate as 968's restore, 972's render and
  974's inbound delivery.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Widget`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "widget_step_proves_message_before_done"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The widget is proven by a message, not by a script tag" do
    scenario "the step confirms an end-to-end message before reporting done" do
      given_ "the widget step has configured everything", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='widget'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it confirmed a real message travelled from the site into CodeMySpec", context do
        parsed = Floki.parse_document!(context.html)

        proof = parsed |> Floki.find("[data-test='widget-message-proof']")

        # Anchor: a message proof exists rather than a markup assertion.
        assert proof != [], "expected the widget step to record a message proof"

        state = proof |> Floki.attribute("data-state") |> List.first()
        origin = proof |> Floki.attribute("data-origin") |> List.first()

        assert state == "received",
               "expected an actual received message, got #{inspect(state)}"

        assert origin == "deployed_site",
               "expected the probe message to originate from the deployed site rather than a local harness, got #{inspect(origin)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the step marked done", context do
        assert context.html =~ ~r/data-step="widget"[^>]*data-state="done"/,
               "expected the widget step to be done once a message was proven"

        proven_at =
          context.parsed
          |> Floki.find("[data-test='widget-message-proof']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='widget']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(proven_at) and is_binary(done_at),
               "expected both the proof and the step completion to be timestamped"

        assert proven_at <= done_at,
               "expected the message proof to precede the step being called done: proven_at=#{proven_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
