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

  # Mounting reads the sending domains off Resend, and the premise is published
  # here rather than left to the step — see the given_ for why.

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "The inbox is proven by a message, not by configuration" do
    scenario "the step confirms an end-to-end delivery before reporting done" do
      given_ "the inbound records are published", context do
        # Its own subdomain. Sharing one name across a story means whichever
        # criterion runs second finds the first's domain already registered and
        # *adopts* it — and an adopted resource is never torn down, so each one
        # replays the others' state.
        # The zone the records go into. Under a cassette this was true because
        # John's Cloudflare manages `astralbi.com`; stated here, so publishing
        # a record means it resolves.
        zone_exists(context, "astralbi.com")

        project = own_domain(context.project, "c8033.astralbi.com")

        # The premise is "the inbound records are published", so publish them
        # here. The step still does the proving — it sends a message and waits
        # for Resend to report it received, which is the whole criterion — but
        # it is not also racing a brand-new domain through DNS propagation and
        # inbound verification inside the run. Recorded that way it sent once
        # and polled sixty times without a receipt.
        #
        # `receiving: true` because Resend grants receiving at creation and
        # never afterwards; a sending-only domain here cannot be upgraded and
        # the probe would be dropped in silence.
        verified_sending_domains(context.scope, project, ["prod"], receiving: true)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        _ = Phoenix.LiveViewTest.render(view)
        view = view

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup verifies the step", context do
        context.view
        |> element("[data-test='setup-step'][data-step='inbound'] [data-test='run-step']")
        |> render_click()

        # The plain "Run" click carries no address, so :inbound settles at
        # :paused rather than :done (7df39199) — its records are already
        # published, and the pause is only about proving delivery. Answer it
        # the way 2f8c4208 gave the page to, then read the page after the
        # run rather than what the click handed back.
        CodeMySpecSpex.Case.await_step(context.view, :inbound)
        CodeMySpecSpex.Case.resolve_inbound_probe_pause(context.view, "sam@c8033.astralbi.com")

        {:ok, Map.put(context, :html, render(context.view))}
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
