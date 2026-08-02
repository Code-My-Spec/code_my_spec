defmodule CodeMySpecSpex.Story974.Criterion8032Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8032 — Receiving mail does not break sending it.

  The mirror image of story 969's criterion 8029. Publishing the inbound
  records leaves the sending domain verified and the app still able to
  send. 974 owns apex MX; 969 owns the `send` subdomain. Each must leave
  the other's records alone, and only asserting it in one direction would
  leave the other free to clobber.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @sending_cassette # Its own cassette. This shared a name with 969's criterion 8025, and record
  # mode deletes the cassette file when it opens — so recording this story
  # silently destroyed another story's recording. Cassette names are global;
  # they need a story prefix.
  "974_8032_sending_records_published"
  @inbound_cassette "resend_inbound_records_published"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Receiving mail does not break sending it" do
    scenario "the sending domain stays verified after inbound records are published" do
      given_ "the app already sends verified mail from Sam's domain", context do
        # Its own subdomain. Sharing one name across a story means whichever
        # criterion runs second finds the first's domain already registered and
        # *adopts* it — and an adopted resource is never torn down, so each one
        # replays the others' state.
        own_domain(context.project, "c8032.astralbi.com")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        before =
          with_provider_cassette(@sending_cassette, fn ->
            view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        # Anchor: sending really was working before inbound touched anything.
        assert before =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected sending to be set up and verified first"

        {:ok,
         context
         |> Map.put(:view, view)
         |> Map.put(:send_records_before, send_records(before))}
      end

      when_ "the inbound step publishes its records", context do
        html =
          with_provider_cassette(@inbound_cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='inbound'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the sending domain is still verified", context do
        verification =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-verification']")
          |> Floki.attribute("data-status")
          |> List.first()

        assert verification == "verified",
               "expected the sending domain to remain verified after inbound setup, got #{inspect(verification)}"

        {:ok, context}
      end

      then_ "the send subdomain's records were left alone", context do
        assert send_records(context.html) == context.send_records_before,
               "expected the send subdomain records to be untouched by inbound setup:\n  before: #{inspect(context.send_records_before)}\n  after:  #{inspect(send_records(context.html))}"

        {:ok, context}
      end

      then_ "the app can still send", context do
        assert context.html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected the email step to remain done after inbound setup"

        {:ok, context}
      end
    end
  end

  defp send_records(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='mail-dns-record']")
    |> Enum.filter(&((&1 |> Floki.attribute("data-name") |> List.first() || "") =~ ~r/^send/))
    |> Enum.map(fn el ->
      {el |> Floki.attribute("data-type") |> List.first(),
       el |> Floki.attribute("data-name") |> List.first(),
       el |> Floki.attribute("data-content") |> List.first()}
    end)
    |> Enum.sort()
  end
end
