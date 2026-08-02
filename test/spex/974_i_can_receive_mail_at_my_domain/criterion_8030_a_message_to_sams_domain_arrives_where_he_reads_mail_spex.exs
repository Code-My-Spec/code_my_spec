defmodule CodeMySpecSpex.Story974.Criterion8030Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8030 — A message to Sam's domain arrives where he reads mail.

  After the inbound step, a message sent to an address at Sam's domain
  arrives where he reads his mail. Sending from a domain you cannot receive
  at means every reply to your own app's mail vanishes.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend` (inbound).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_inbound_probe_delivered"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A message to Sam's domain arrives where he reads mail" do
    scenario "an inbound probe is delivered to Sam's destination" do
      given_ "the inbound step has run", context do
        # Its own subdomain. Sharing one name across a story means whichever
        # criterion runs second finds the first's domain already registered and
        # *adopts* it — and an adopted resource is never torn down, so each one
        # replays the others' state.
        own_domain(context.project, "c8030.astralbi.com")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "someone sends a message to an address at his domain", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='mail-inbound-probe']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it arrives where Sam reads his mail", context do
        delivery =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='inbound-delivery']")

        # Anchor: an inbound probe was attempted and recorded.
        assert delivery != [], "expected the inbound probe to be recorded"

        state = delivery |> Floki.attribute("data-state") |> List.first()
        destination = delivery |> Floki.attribute("data-destination") |> List.first()

        assert state == "delivered",
               "expected the message to be delivered, got #{inspect(state)}"

        assert is_binary(destination) and destination != "",
               "expected the delivery to name where it landed"

        {:ok, context}
      end
    end
  end
end
