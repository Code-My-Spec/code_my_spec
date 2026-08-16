defmodule CodeMySpecSpex.Story974.Criterion8030Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8030 — A message to Sam's domain arrives where he reads mail.

  Setup does not report an inbox on the strength of having published MX
  records. It sends a message to the domain and waits for the provider to say
  it arrived, and names where it landed — the same prove-it-before-claiming-it
  gate as the backup restore in 968 and the render check in 972.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend` (inbound).

  ## Against fakes, not cassettes

  Rewritten 2026-08-16. The claim is that setup *proves* delivery rather than
  assuming it — which is a claim about our gate, not about Resend's network.
  Whether a message really crosses the internet is the drill's to answer.

  Its cassettes could never replay, for a reason worth keeping: the probe's
  destination is derived from a per-run user email whose local part is random
  (a053b5dd), so the recorded request never matched the next run's. Against a
  fake the address is whatever the run uses, and the delivery is looked up by
  the domain rather than by a string recorded on some earlier day.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A message to Sam's domain arrives where he reads mail" do
    scenario "an inbound probe is delivered to Sam's destination" do
      given_ "the inbound step has run", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        view = mount_provisioning(context)

        # Sending first: Resend grants receiving on a domain it already knows,
        # and an inbox on a domain it does not is the case that silently drops
        # every probe.
        for step <- [:email, :inbound] do
          view
          |> element("[data-test='setup-step'][data-step='#{step}'] [data-test='run-step']")
          |> render_click()

          CodeMySpecSpex.Case.await_step(view, step)
        end

        assert render(view) =~ ~r/data-step="inbound"[^>]*data-state="done"/,
               "expected inbound to be set up before a probe is sent to it"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "someone sends a message to an address at his domain", context do
        html = click_inbound_probe(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it arrives where Sam reads his mail", context do
        delivery =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='inbound-delivery']")

        # Anchor: an inbound probe was attempted and recorded.
        assert delivery != [], "expected the inbound probe to be recorded, and none was"

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
