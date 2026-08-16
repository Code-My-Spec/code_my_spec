defmodule CodeMySpecSpex.Story969.Criterion8024Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8024 — Sam's domain is known to the mail provider.

  Setup registers the domain with Resend itself. Sam does not add it by
  hand in their dashboard — the whole point is that he pastes a key once
  and the posture assembles itself.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Sam's domain is known to the mail provider" do
    scenario "the email step registers the domain with the provider" do
      given_ "Sam owns his domain", context do
        # Its own subdomain. Every criterion in this story used one shared name,
        # so whichever ran second found the first's sending domain already
        # registered and *adopted* it — and an adopted resource is never torn
        # down. Recorded alone each one passed; run together they replayed each
        # other's state.
        # The zone the records go into. Under a cassette this was true because
        # John's Cloudflare manages `astralbi.com`; stated here, so publishing
        # a record means it resolves.
        zone_exists(context, "astralbi.com")

        project = own_domain(context.project, "c8024.astralbi.com")
        verified_sending_domains(context.scope, project)
        tear_down_after(context.scope, [:email])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the email step runs", context do
        context.view
        |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
        |> render_click()

        # The page *after* the run, not what the click handed back. The
        # mail section is assigned when the step announces itself
        # (`handle_info({:provisioning, :step, …})` refreshes it), which
        # happens after the event that `render_click/1` returns from — so
        # its return value shows the page before the domain existed, and
        # the criterion read an empty section as "nothing was registered".
        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the domain is registered with the mail provider for sending", context do
        domain =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-sending-domain']")

        # Anchor: a sending domain was recorded at all.
        assert domain != [], "expected the email step to record the sending domain it registered"

        provider_id = domain |> Floki.attribute("data-provider-id") |> List.first()

        assert is_binary(provider_id) and provider_id != "",
               "expected the provider's own id for the domain, proving it was registered rather than assumed"

        {:ok, Map.put(context, :domain, domain)}
      end

      then_ "Sam did not add it by hand in their dashboard", context do
        manual = context.domain |> Floki.attribute("data-manual-step-required") |> List.first()

        assert manual == "false",
               "expected no manual dashboard step for registering the sending domain, got #{inspect(manual)}"

        {:ok, context}
      end
    end
  end
end
