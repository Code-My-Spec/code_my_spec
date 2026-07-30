defmodule CodeMySpecSpex.Story969.Criterion8026Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8026 — Setup waits for verification rather than assuming it.

  After publishing the records, setup polls the provider until it reports
  verified, and only then marks the email step done. Verification takes
  minutes and resolvers negative-cache; a step that publishes records and
  declares victory leaves Sam with an unverified domain and mail that 403s
  on the first send.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_domain_verify_pending_then_verified"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Setup waits for verification rather than assuming it" do
    scenario "the step polls to verified before reporting done" do
      given_ "the records have been published", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup checks the domain's status", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it kept checking until the provider reported verified", context do
        parsed = Floki.parse_document!(context.html)

        verification =
          parsed
          |> Floki.find("[data-test='mail-verification']")

        # Anchor: verification was tracked at all.
        assert verification != [], "expected the email step to record its verification polling"

        status = verification |> Floki.attribute("data-status") |> List.first()
        attempts = verification |> Floki.attribute("data-attempts") |> List.first()

        assert status == "verified",
               "expected the provider to have reported verified, got #{inspect(status)}"

        assert is_binary(attempts) and String.to_integer(attempts) > 1,
               "expected setup to have polled rather than accepted the first pending answer, attempts=#{inspect(attempts)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the email step done", context do
        assert context.html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected the email step to be done once verification cleared"

        verified_at =
          context.parsed
          |> Floki.find("[data-test='mail-verification']")
          |> Floki.attribute("data-verified-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='email']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(verified_at) and is_binary(done_at),
               "expected both verification and step completion to be timestamped"

        assert verified_at <= done_at,
               "expected verification to precede the step being called done: verified_at=#{verified_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
