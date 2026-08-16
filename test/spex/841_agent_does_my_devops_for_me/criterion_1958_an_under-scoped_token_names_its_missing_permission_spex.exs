defmodule CodeMySpecSpex.Story841.Criterion1958Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1958 — An under-scoped token names its missing permission.

  A token the provider recognises but refuses is not a bad token. Telling Sam
  "invalid credential" sends him to mint a new one with the same permissions
  and hit the same wall. The answer has to name the permission that was
  missing, so the fix is "add Registrar write" rather than "try again".

  Surface: `ProvisioningLive`, checking credentials against the providers. The
  check is a real call — a token that looks right and cannot do the job is
  precisely what this criterion is about, so nothing here asserts on format.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # The provider that refuses. This criterion had no provider setup at all —
  # the cassette *was* the provider, answering the check with a recorded 403 —
  # so without a fake the check finds nothing configured and reports
  # "unchecked", which is a third state and not the one under test.
  setup :fake_providers

  spex "An under-scoped token names its missing permission" do
    scenario "a token the provider accepts but will not act on" do
      given_ "Sam has entered a token that the provider will refuse", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='credentials-form']",
          credentials: %{"hetzner_api_token" => "spex-read-only-token"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the credentials are checked against the providers", context do
        html =
          context.view |> element("[data-test='check-credentials']") |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the token reads rejected rather than missing", context do
        state =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='credential-field'][data-credential='hetzner_api_token']")
          |> Floki.attribute("data-state")
          |> List.first()

        assert state == "rejected",
               "expected a recognised-but-refused token to read rejected, got #{inspect(state)}"

        {:ok, context}
      end

      then_ "the permission it lacks is named on the page", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='credential-field'][data-credential='hetzner_api_token']")
          |> Floki.text()

        assert text =~ "Read & Write",
               "expected the missing permission to be named so Sam knows what to change, got: #{text}"

        {:ok, context}
      end
    end
  end
end
