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
  setup :devops_on

  spex "An option turned off does not ask for its credential" do
    scenario "with email off, no Resend credential is requested" do
      given_ "Sam has turned the email option off", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Both mail options. Resend backs sending *and* receiving, so turning
        # off only `:email` leaves `:inbound` still needing the same
        # credential — and the criterion would fail against correct
        # behaviour. "The email option" is the mail feature, not one step.
        #
        # The form is phx-change and its params are
        # `options[<key>]`, so a submit with a `provisioning` map changed
        # nothing — the page kept every default and the criterion passed for
        # the wrong reason.
        choose_all_setup_options_except(view, [:email, :inbound])

        {:ok, context}
      end

      when_ "he opens credential entry", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

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
