defmodule CodeMySpecSpex.Story969.Criterion8028Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8028 — A real message arrives from Sam's domain.

  With the domain verified and the app deployed, a message the app sends
  arrives from an address at Sam's domain and is not rejected as
  unauthenticated. This is the criterion that proves the DKIM/SPF work
  actually bought deliverability rather than just green ticks in a
  dashboard.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_send_probe_message_accepted"

  # The `given_` registers and verifies a sending domain and then mounts the
  # page, which reads mail state from Resend — all real provider calls. Left
  # outside a cassette they hit the live API while recording and the network
  # while replaying, so the page came up knowing about a verified domain when
  # recording and knowing nothing when replaying, and the send-probe control
  # the `when_` clicks was simply absent.
  @given_cassette "969_8028_verified_domain"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A real message arrives from Sam's domain" do
    scenario "the probe send is accepted and authenticated" do
      given_ "the domain is verified and the app is deployed", context do
        # Its own subdomain. Every criterion in this story used one shared name,
        # so whichever ran second found the first's sending domain already
        # registered and *adopted* it — and an adopted resource is never torn
        # down. Recorded alone each one passed; run together they replayed each
        # other's state.
        project = own_domain(context.project, "c8028.astralbi.com")
        tear_down_after(context.scope, [:email])

        view =
          with_provider_cassette(@given_cassette, fn ->
            verified_sending_domains(context.scope, project)

            {:ok, view, _html} =
              live(context.conn, "/app/projects/#{context.project.id}/provisioning")

            view
          end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the app sends a message", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='mail-send-probe']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it arrives from an address at Sam's domain", context do
        probe =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-send-result']")

        # Anchor: a send was attempted and recorded.
        assert probe != [], "expected the send probe to be recorded"

        from = probe |> Floki.attribute("data-from") |> List.first()
        accepted = probe |> Floki.attribute("data-accepted") |> List.first()

        assert accepted == "true",
               "expected the provider to accept the message, got #{inspect(accepted)}"

        assert is_binary(from) and from =~ "@",
               "expected the message to be sent from an address at Sam's domain, got #{inspect(from)}"

        {:ok, Map.put(context, :probe, probe)}
      end

      then_ "it is not rejected as unauthenticated", context do
        dkim = context.probe |> Floki.attribute("data-dkim") |> List.first()

        assert dkim == "pass",
               "expected the message to be DKIM-signed for Sam's domain, got #{inspect(dkim)}"

        refute context.html =~ ~r/data-test="mail-send-result"[^>]*data-status="403"/,
               "expected no unverified-domain rejection"

        {:ok, context}
      end
    end
  end
end
