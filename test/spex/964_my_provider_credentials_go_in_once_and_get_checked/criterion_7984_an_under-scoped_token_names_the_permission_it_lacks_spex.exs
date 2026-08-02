defmodule CodeMySpecSpex.Story964.Criterion7984Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7984 — An under-scoped token names the permission it lacks.

  A Cloudflare token that can edit DNS but cannot register domains is
  rejected, and the rejection names Registrar write specifically. "Token
  invalid" is not good enough — Sam has to know which permission to add,
  and no domain may have been bought in the meantime.

  The provider's permission-denied response is replayed from a
  ReqCassette; the spec drives the LiveView and the cassette intercepts
  the app's outbound Req call.

  Surface: `CodeMySpecWeb.CredentialsLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_token_missing_registrar_write"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "An under-scoped token names the permission it lacks" do
    scenario "a DNS-only Cloudflare token is rejected naming Registrar write" do
      given_ "Sam is on credential entry", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      # Checked, not submitted. Cloudflare is connected by OAuth on the
      # account — there is no token field to type into, and the under-scoping
      # is a property of the grant rather than of something Sam pasted. So the
      # question "can this credential do the job" is answered by using it,
      # which is what the check does.
      when_ "his Cloudflare grant is checked against the provider", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='check-credentials']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the token is rejected naming Registrar write as what is missing", context do
        assert has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential='cloudflare_token'][data-state='rejected']"
               ),
               "expected the under-scoped Cloudflare token to be rejected"

        assert context.html =~ "Registrar",
               "expected the rejection to name the Registrar permission, not just 'invalid token'"

        {:ok, context}
      end

      then_ "no domain has been bought", context do
        {:ok, provisioning, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        refute has_element?(
                 provisioning,
                 "[data-test='setup-step'][data-step='domain'][data-state='done']"
               ),
               "expected the domain step to remain unrun after a rejected credential"

        {:ok, context}
      end
    end
  end
end
