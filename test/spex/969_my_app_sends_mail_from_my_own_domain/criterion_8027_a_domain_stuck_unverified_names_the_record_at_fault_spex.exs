defmodule CodeMySpecSpex.Story969.Criterion8027Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8027 — A domain stuck unverified names the record at fault.

  When the domain has not verified after a reasonable wait, setup gives up
  waiting and reports *which* record is not as the provider expects — and
  does not mark email done. The usual cause is a typoed DKIM TXT, and
  "verification timed out" leaves Sam diffing three records by eye.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_domain_verify_stuck_dkim_mismatch"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A domain stuck unverified names the record at fault" do
    scenario "the timeout reports the mismatching record and leaves email unfinished" do
      given_ "the domain has not verified after a reasonable wait", context do
        stuck_sending_domain(context.scope, context.project, context)
        tear_down_after(context.scope, [:email])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup gives up waiting", context do
        html =
          # First-match rather than sequential. The premise here is a domain
          # that never verifies, so every poll legitimately returns the same
          # unverified answer — there is no sequence to preserve. Sequential
          # matching only made the cassette exhaustible, so the page reloading
          # once more on replay than it did while recording failed the run for
          # a reason unrelated to the claim.
          with_provider_cassette(@cassette, [sequential: false], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it reports which record is not as the provider expects", context do
        parsed = Floki.parse_document!(context.html)

        # Regrounded on what the provider actually reports. Resend marks every
        # record — and the domain — `pending` until *all* of them pass; it
        # never reports one record verified and another not, so "some verified,
        # one at fault" was not a state its API can produce. Verified against
        # the live API, not inferred from the docs.
        #
        # The specific fault is still nameable, and setup is what names it: the
        # page checks each record the provider asked for against a public
        # resolver, so the one that does not resolve is identified by us rather
        # than by Resend. That is the claim worth making — it is also the one
        # that tells Sam what to go fix.
        resolving =
          parsed |> Floki.find("[data-test='mail-dns-record'][data-resolved='true']")

        assert resolving != [],
               "expected the published records to resolve, so the fault is specific rather than blanket"

        faulted =
          parsed |> Floki.find("[data-test='mail-dns-record'][data-resolved='false']")

        assert faulted != [],
               "expected the record that does not resolve to be identified"

        names = Enum.map(faulted, &(Floki.attribute(&1, "data-name") |> List.first()))

        assert Enum.any?(names, &(&1 =~ ~r/_domainkey/)),
               "expected the DKIM record to be named as the fault, got #{inspect(names)}"

        {:ok, context}
      end

      then_ "it does not mark email done", context do
        refute context.html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected email to remain unfinished while the domain is unverified"

        {:ok, context}
      end
    end
  end
end
