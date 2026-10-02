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

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  probe moved off ProvisioningLive's blocking click into mail's Checks tab,
  behind DiagnosticsPanel, running async via `start_async` — same move
  criterion 613 made for the storage round-trip probe. `:email` and
  `:inbound` run through `run_console_step/2`/`resolve_console_pause/3`,
  the console's own support helpers, since `run_step_interaction` and
  `resolve_inbound_probe_pause/2` are coupled to the old page's `setup-step`
  markup. `click_inbound_probe/1` is unchanged — it already selects by
  `data-test`, which the ported markup kept.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  defp mail_inbound_done?(html),
    do: not (html =~ ~s(data-test="mail-inbound-probe-panel" data-state="running"))

  spex "A message to Sam's domain arrives where he reads mail", criterion: 651 do
    scenario "an inbound probe is delivered to Sam's destination" do
      given_ "the inbound step has run", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/mail")

        # Sending first: Resend grants receiving on a domain it already knows,
        # and an inbox on a domain it does not is the case that silently drops
        # every probe.
        for step <- [:email, :inbound], do: run_console_step(view, step)

        # The plain "Run" click above carries no address, so :inbound settles
        # at :paused rather than :done (7df39199) — its records are already
        # published, and the pause is only about proving delivery. Answer it
        # the way 2f8c4208 gave the page to.
        resolve_console_pause(view, :inbound, "sam@#{@domain}")

        assert render(view) =~ ~r/data-step="inbound"[^>]*data-state="done"/,
               "expected inbound to be set up before a probe is sent to it"

        open_resource_tab(view, :mail, "checks")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "someone sends a message to an address at his domain", context do
        click_inbound_probe(context.view)

        html = await_operation(context.view, &mail_inbound_done?/1, &mail_inbound_done?/1)

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
