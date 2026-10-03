defmodule CodeMySpecSpex.Story964.Criterion7983Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7983 — A credential is proven by a real call, not by looking right.

  Submitting a token makes an actual call to the provider and reports
  verified only on the provider's answer. A well-formed-looking token
  that the provider rejects must not read as verified, which is why the
  check cannot be a format assertion.

  The provider round-trip is replayed from a ReqCassette so the spec is
  deterministic while still exercising the app's real Req client — the
  spec drives the LiveView and the cassette intercepts the app's
  outbound HTTP, rather than the spec stubbing the surface under test.

  Retargeted onto the console (provisioning-console-step6, unmerged): see
  criterion 613's moduledoc. Credentials live on their own plain page now
  (`/console/credentials`) with the form always visible, so there is no
  `manage-credentials` dialog to open first. "Nothing has been provisioned
  yet" is checked against the Overview page's project-wide
  `setup-checklist-item` listing, the console's equivalent of the old page's
  full `setup-step` list, since no single resource-group page shows every
  step at once.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A credential is proven by a real call, not by looking right", criterion: 579 do
    scenario "the Hetzner token is confirmed against Hetzner before it reads verified" do
      given_ "Sam is on credential entry", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        {:ok, Map.put(context, :view, view)}
      end

      # The real token when recording, a placeholder otherwise. Recording with
      # a literal "valid-looking-token" would capture a 401 — a cassette that
      # replays perfectly and proves the opposite of the criterion.
      when_ "he submits his Hetzner API token", context do
        context.view
        |> form("[data-test='credentials-form']",
          credentials: %{
            hetzner_api_token: System.get_env("HETZNER_API_TOKEN", "spex-placeholder-token")
          }
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the credential reads verified on the provider's answer", context do
        assert has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential='hetzner_api_token'][data-state='verified']"
               ),
               "expected the Hetzner token to be marked verified after the provider confirmed it"

        {:ok, context}
      end

      then_ "nothing has been provisioned yet", context do
        {:ok, overview, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console")

        refute has_element?(overview, "[data-test='setup-checklist-item'][data-state='done']"),
               "expected credential verification to provision nothing"

        {:ok, context}
      end
    end
  end
end
