defmodule CodeMySpecSpex.Story974.Criterion8033Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8033 — The inbox is proven by a message, not by configuration.

  Setup does not call the inbox done until a real message has been
  delivered end to end. Published MX records that look right are the
  normal state of a broken mail setup; the only proof is a message
  arriving.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend` (inbound).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_inbound_step_proves_delivery_before_done"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The inbox is proven by a message, not by configuration" do
    scenario "the step confirms an end-to-end delivery before reporting done" do
      given_ "the inbound records are published", context do
        # Its own subdomain. Sharing one name across a story means whichever
        # criterion runs second finds the first's domain already registered and
        # *adopts* it — and an adopted resource is never torn down, so each one
        # replays the others' state.
        own_domain(context.project, "c8033.astralbi.com")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup verifies the step", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='inbound'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it confirms a real message was delivered end to end", context do
        parsed = Floki.parse_document!(context.html)

        proof = parsed |> Floki.find("[data-test='inbound-delivery-proof']")

        # Anchor: a delivery proof exists, not merely a record listing.
        assert proof != [], "expected the inbound step to record a delivery proof"

        state = proof |> Floki.attribute("data-state") |> List.first()

        assert state == "delivered",
               "expected an actual delivery rather than a configuration check, got #{inspect(state)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the inbox marked done", context do
        assert context.html =~ ~r/data-step="inbound"[^>]*data-state="done"/,
               "expected the inbound step to be done once delivery was proven"

        proven_at =
          context.parsed
          |> Floki.find("[data-test='inbound-delivery-proof']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='inbound']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(proven_at) and is_binary(done_at),
               "expected both the proof and the step completion to be timestamped"

        assert proven_at <= done_at,
               "expected delivery to be proven before the step was called done: proven_at=#{proven_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
