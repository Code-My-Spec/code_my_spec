defmodule CodeMySpecSpex.Story974.Criterion8048Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8048 — The app can act on a message someone sent in.

  Inbound mail is addressable by the app, not merely forwarded to a mailbox
  Sam reads. This is the reason Resend Inbound was chosen over Cloudflare
  Email Routing: the app receives the message and can act on its contents —
  parse a reply, turn mail into a ticket — without Sam forwarding anything
  by hand.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend` (inbound).

  ## Against fakes, not cassettes

  Rewritten 2026-08-16. What this criterion claims is about *our* handling —
  that the message reaches the app with its contents available, rather than
  being forwarded somewhere a person has to look. Whether Resend delivers is
  Resend's business and belongs to the drill.

  The old version needed two cassettes and a real domain because everything
  had to be arranged through the provider: a receiving-enabled domain, a
  mail section that only renders once Resend knows about a sending domain,
  and an inbound probe whose destination is derived from a per-run email
  address — which is why it could never replay (a053b5dd).

  The fake delivers a message addressed to a receiving-enabled domain back
  through `GET /emails/receiving`, exactly as Resend does, and refuses to for
  a sending-only one — which is the distinction that cost this story a night.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "The app can act on a message someone sent in" do
    scenario "an inbound message is delivered to the app, not just forwarded" do
      given_ "inbound mail is set up", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        view = mount_provisioning(context)

        # Both steps, because an inbox needs a verified sending domain behind
        # it — Resend grants receiving on a domain it already knows.
        for step <- [:email, :inbound] do
          view
          |> element("[data-test='setup-step'][data-step='#{step}'] [data-test='run-step']")
          |> render_click()

          CodeMySpecSpex.Case.await_step(view, step)
        end

        html = render(view)

        assert html =~ ~r/data-step="inbound"[^>]*data-state="done"/,
               "expected inbound to be set up before a message is sent to it"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "someone sends a message to an address the app owns", context do
        html = click_inbound_probe(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the app receives it and can act on its contents", context do
        delivery =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='inbound-delivery']")

        # Anchor: the message was delivered at all.
        assert delivery != [],
               "expected the inbound message to be recorded, and none was"

        target = delivery |> Floki.attribute("data-delivered-to") |> List.first()

        assert target == "app",
               "expected the message to reach the app rather than only a mailbox, got " <>
                 "#{inspect(target)}"

        body_available = delivery |> Floki.attribute("data-body-available") |> List.first()

        assert body_available == "true",
               "expected the app to have the message contents available to act on"

        {:ok, Map.put(context, :delivery, delivery)}
      end

      then_ "Sam did not have to forward it there himself", context do
        forwarded_by_hand = context.delivery |> Floki.attribute("data-manual-forward") |> List.first()

        assert forwarded_by_hand == "false",
               "expected no manual forwarding step, got #{inspect(forwarded_by_hand)}"

        {:ok, context}
      end
    end
  end
end
