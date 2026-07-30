defmodule CodeMySpecSpex.Story963.Criterion7973Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7973 — A failure the agent cannot fix stops and names itself.

  The repair loop has a floor. Some failures the agent genuinely cannot
  fix — no payment method on file is Sam's errand, not an agent's — and
  in that case setup stops rather than retrying indefinitely, and the
  status page says what Sam has to do himself.

  Without this, automatic escalation becomes an infinite loop burning
  provider calls on something no amount of retrying will resolve.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @unfixable_cassette "cloudflare_registrar_no_payment_method"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A failure the agent cannot fix stops and names itself" do
    scenario "a missing payment method stops the run and names Sam's errand" do
      given_ "the domain step will fail because Sam has no payment method on file", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the setup agent attempts a fix and cannot", context do
        ReqCassette.with_cassette(@unfixable_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup stops at that step rather than retrying indefinitely", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected the domain step to come to rest as errored"

        attempts =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='domain']")
          |> Floki.attribute("data-repair-attempts")
          |> List.first()

        assert attempts != nil,
               "expected the step to record how many repair attempts were made"

        assert String.to_integer(attempts) <= 3,
               "expected repair attempts to be bounded, got #{attempts}"

        {:ok, context}
      end

      then_ "the page says what Sam has to do himself", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='needs-sam'][data-step='domain']")
          |> Floki.text()

        assert text =~ ~r/payment/i,
               "expected the page to name the payment method as Sam's errand, got: #{inspect(text)}"

        {:ok, context}
      end
    end
  end
end
