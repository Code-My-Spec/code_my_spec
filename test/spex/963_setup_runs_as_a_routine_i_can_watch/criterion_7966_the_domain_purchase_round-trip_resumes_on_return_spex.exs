defmodule CodeMySpecSpex.Story963.Criterion7966Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7966 — The domain purchase round-trip resumes on return.

  Some work Sam has to do elsewhere. When the TLD sits outside what the
  Registrar API can sell, setup pauses and tells him exactly what to do
  in the Cloudflare dashboard — then, when he comes back, finds the
  registered domain and carries on to the next step. Pausing without
  telling him what to do, or losing the run while he is away, both fail
  this.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint


  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The domain purchase round-trip resumes on return" do
    scenario "an unsellable TLD pauses with instructions rather than failing" do
      given_ "the domain Sam wants has a TLD the Registrar API cannot sell", context do
        # A pause, not an error: the run stops and hands Sam an errand it
        # cannot do for him. Scripting the pause makes the instructions
        # deterministic, where the old version depended on the registrar
        # continuing to refuse this particular TLD.
        # Pauses the first time and finds the domain the next, which is the
        # round trip the criterion is named for: Sam goes and registers it by
        # hand, comes back, and setup adopts what is now there.
        {:ok, visits} = Agent.start_link(fn -> 0 end)

        context =
          scripted_run(context, %{
            domain: fn ->
              case Agent.get_and_update(visits, &{&1 + 1, &1 + 1}) do
                1 ->
                  {:paused,
                   "This TLD cannot be bought through the Registrar API. Register it in the Cloudflare dashboard, then run this step again."}

                _ ->
                  {:ok, [%{kind: "domain", location: "cloudflare/his-app.dev", origin: "adopted"}]}
              end
            end
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs", context do
        context.view |> element("[data-test='start-setup']") |> render_click()
        html = await_provisioning(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup pauses and tells him what to do in the Cloudflare dashboard", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected the domain step to pause rather than error or press on"

        instructions =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='paused-instructions'][data-step='domain']")
          |> Floki.text()

        assert instructions =~ ~r/dashboard|cloudflare/i,
               "expected the pause to say what to do in the dashboard, got: #{inspect(instructions)}"

        {:ok, context}
      end

      then_ "when Sam returns, setup finds the domain and continues", context do
        context.view |> element("[data-test='resume-setup']") |> render_click()
        html = await_provisioning(context.view)

        assert html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected setup to adopt the manually registered domain on return; steps: " <>
                 (html
                  |> Floki.parse_document!()
                  |> Floki.find("[data-test='setup-step']")
                  |> Enum.map_join(", ", fn s ->
                    "#{s |> Floki.attribute("data-step") |> List.first()}=#{s |> Floki.attribute("data-state") |> List.first()}"
                  end))

        refute html =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected the pause to clear once the domain existed"

        {:ok, context}
      end
    end
  end
end
