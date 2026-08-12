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
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_inbound_message_reaches_app"

  # Mounting reads the sending domains off Resend; outside a cassette the mail
  # section is simply not there. Same wall 8029 and 8030 hit.
  @mount_cassette "974_8048_mail_section_mounted"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The app can act on a message someone sent in" do
    scenario "an inbound message is delivered to the app, not just forwarded" do
      given_ "inbound mail is set up", context do
        # Its own subdomain. Sharing one name across a story means whichever
        # criterion runs second finds the first's domain already registered and
        # *adopts* it — and an adopted resource is never torn down, so each one
        # replays the others' state.
        project = own_domain(context.project, "c8048.astralbi.com")

        view =
          with_provider_cassette(@mount_cassette, fn ->
            # The mail section — which the probe control lives in — renders off
            # a sending domain Resend knows about, so the project's domain
            # alone leaves it off the page. `receiving: true` because this
            # criterion is about an inbox, and Resend grants receiving at
            # creation or never.
            verified_sending_domains(context.scope, project, ["prod"], receiving: true)

            {:ok, view, _html} =
              live(context.conn, "/app/projects/#{context.project.id}/provisioning")

            _ = Phoenix.LiveViewTest.render(view)
            view
          end)

        assert Phoenix.LiveViewTest.render(view) =~ ~s(data-test="mail"),
               "expected the mail section to render — the probe control lives inside it"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "someone sends a message to an address the app owns", context do
        # Addressed to a mailbox that exists when RESEND_SPEX_INBOX names one.
        # The default address comes from the fixture user's email, whose local
        # part is random, so on a domain created moments ago it is delivered
        # nowhere — Resend accepts the send, returns an id, and drops it.
        html =
          with_provider_cassette(@cassette, fn ->
            click_inbound_probe(context.view)
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the app receives it and can act on its contents", context do
        delivery =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='inbound-delivery']")

        # Anchor: the message was delivered at all.
        assert delivery != [], "expected the inbound message to be recorded"

        target = delivery |> Floki.attribute("data-delivered-to") |> List.first()

        assert target == "app",
               "expected the message to reach the app rather than only a mailbox, got " <>
                 "#{inspect(target)}. state=#{inspect(Floki.attribute(delivery, "data-state"))} " <>
                 "#{Floki.text(delivery) |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)}"

        body_available = delivery |> Floki.attribute("data-body-available") |> List.first()

        assert body_available == "true",
               "expected the app to have the message contents available to act on"

        {:ok, Map.put(context, :delivery, delivery)}
      end

      then_ "Sam did not have to forward it there himself", context do
        forwarded_by_hand =
          context.delivery |> Floki.attribute("data-manual-forward") |> List.first()

        assert forwarded_by_hand == "false",
               "expected no manual forwarding step, got #{inspect(forwarded_by_hand)}"

        {:ok, context}
      end
    end
  end
end
