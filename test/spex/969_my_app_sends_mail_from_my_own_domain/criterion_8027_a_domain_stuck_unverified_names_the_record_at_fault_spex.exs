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

  spex "A domain stuck unverified names the record at fault" do
    scenario "the timeout reports the mismatching record and leaves email unfinished" do
      given_ "the domain has not verified after a reasonable wait", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup gives up waiting", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it reports which record is not as the provider expects", context do
        parsed = Floki.parse_document!(context.html)

        faulted =
          parsed
          |> Floki.find("[data-test='mail-dns-record'][data-verified='false']")

        # Anchor: some records did verify, so naming the failing one is
        # meaningful rather than a blanket failure.
        verified =
          parsed |> Floki.find("[data-test='mail-dns-record'][data-verified='true']")

        assert verified != [],
               "expected at least one record to have verified, so the fault is specific"

        assert faulted != [],
               "expected the unverified record to be identified"

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
