defmodule CodeMySpecSpex.Story969.Criterion8029Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8029 — Existing inbound mail survives the sending setup.

  If Sam already receives mail at his domain, publishing the sending
  records leaves that working. No record inbound delivery depends on is
  replaced — the bounce MX goes on the `send` subdomain, and apex MX is
  left exactly as it was.

  This is the paired constraint with story 974, which owns apex MX. Our own
  knowledge base warns against deleting apex MX blindly during a provider
  migration, and this is the spec that holds that line.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @existing_cassette "cloudflare_apex_mx_already_present"
  # Its own cassette, not 8025's. `with_provider_cassette` deletes the file
  # when it opens in record mode, so two spex naming the same cassette means
  # whichever records second erases the first's interactions.
  @sending_cassette "969_8029_records_published_and_resolved"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Existing inbound mail survives the sending setup" do
    scenario "apex MX is untouched by publishing the sending records" do
      given_ "Sam already receives mail at his domain", context do
        # Its own subdomain. Every criterion in this story used one shared name,
        # so whichever ran second found the first's sending domain already
        # registered and *adopted* it — and an adopted resource is never torn
        # down. Recorded alone each one passed; run together they replayed each
        # other's state.
        project = own_domain(context.project, "c8029.astralbi.com")

        # "Already receives mail" has to be true before the step runs, or the
        # criterion asserts that setup left alone something that was never
        # there.
        tear_down_after(context.scope, [:email])

        # Publishing the apex MX, registering the sending domain and mounting
        # the page are all real provider calls. Outside a cassette they reach
        # the live API while recording and the network while replaying, so the
        # page came up knowing about a verified domain when recording and
        # nothing when replaying.
        before =
          with_provider_cassette(@existing_cassette, fn ->
            existing_apex_mx(context.scope, project)
            verified_sending_domains(context.scope, project)

            {:ok, view, _html} =
              live(context.conn, "/app/projects/#{context.project.id}/provisioning")

            Process.put(:spex_view, view)

            view |> element("[data-test='dns-refresh']") |> render_click()
          end)

        view = Process.get(:spex_view)

        apex_before = apex_mx(before)

        # Anchor: there really was inbound mail to preserve.
        assert apex_before != [],
               "expected an existing apex MX record before the sending setup runs"

        {:ok, context |> Map.put(:view, view) |> Map.put(:apex_before, apex_before)}
      end

      when_ "the email step publishes its sending records", context do
        html =
          with_provider_cassette(@sending_cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "mail sent to his domain still reaches him", context do
        assert apex_mx(context.html) == context.apex_before,
               "expected apex MX to be unchanged:\n  before: #{inspect(context.apex_before)}\n  after:  #{inspect(apex_mx(context.html))}"

        {:ok, context}
      end

      then_ "no record inbound delivery depends on was replaced", context do
        deletions =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='dns-record-deleted']")
          |> Enum.map(&(Floki.attribute(&1, "data-name") |> List.first()))

        refute Enum.any?(deletions, &(&1 in ["@", ""])),
               "expected no apex record to be deleted by the sending setup, deleted: #{inspect(deletions)}"

        {:ok, context}
      end
    end
  end

  defp apex_mx(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='mail-dns-record'][data-type='MX'][data-name='@']")
    |> Enum.map(&(Floki.attribute(&1, "data-content") |> List.first()))
    |> Enum.sort()
  end
end
