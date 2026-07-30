defmodule CodeMySpecSpex.Story964.Criterion7982Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7982 — An option turned off does not ask for its credential.

  Intake is derived from the chosen options, not a fixed list. With the
  email option off, Sam is never asked for a Resend key — the field is
  absent rather than present-and-optional.

  Surface: `CodeMySpecWeb.CredentialsLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An option turned off does not ask for its credential" do
    scenario "with email off, no Resend credential is requested" do
      given_ "Sam has turned the email option off", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='setup-options-form']", provisioning: %{email: false})
        |> render_submit()

        {:ok, context}
      end

      when_ "he opens credential entry", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/credentials")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "he is not asked for a Resend key", context do
        # Anchor: other credentials are still requested, so this is a real
        # absence rather than an empty page.
        assert has_element?(context.view, "[data-test='credential-field']"),
               "expected intake to still ask for the remaining credentials"

        refute has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential^='resend']"
               ),
               "expected no Resend credential field when the email option is off"

        {:ok, context}
      end
    end
  end
end
