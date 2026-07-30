defmodule CodeMySpecSpex.Story964.Criterion8051Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 8051 — Another project's credentials are not reachable.

  Credentials are scoped to the project that owns them. A user with two
  projects on different provider accounts must not have one project's
  run reaching for the other's keys — so the second project's intake
  starts empty even though the first project's is populated.

  Surface: `CodeMySpecWeb.CredentialsLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Another project's credentials are not reachable" do
    scenario "a second project's intake is empty while the first is populated" do
      given_ "the first project has a credential stored", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/credentials")

        view
        |> form("[data-test='credentials-form']",
          credentials: %{hetzner_api_token: "first-project-token"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "Sam also owns a second project", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/new")

        form_live
        |> form("[data-test='project-form']", project: %{name: "second-project"})
        |> render_submit()

        {:ok, index, html} = live(context.conn, "/app/projects")

        assert html =~ "second-project",
               "expected the second project to be created so the isolation check is meaningful"

        {:ok, Map.put(context, :index, index)}
      end

      when_ "he opens credential entry for the second project", context do
        second_id =
          context.index
          |> render()
          |> Floki.parse_document!()
          |> Floki.find("[data-test='project-row'][data-name='second-project']")
          |> Floki.attribute("data-id")
          |> List.first()

        {:ok, view, html} =
          live(context.conn, "/app/projects/#{second_id}/credentials")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the first project's credential is not there", context do
        # Anchor: intake rendered for the second project, so the absence
        # below is real rather than an empty page.
        assert has_element?(context.view, "[data-test='credentials-form']"),
               "expected the second project's credential intake to render"

        refute has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential='hetzner_api_token'][data-stored='true']"
               ),
               "expected the second project to hold no credential of its own"

        refute context.html =~ "first-project-token",
               "expected the first project's value never to surface on another project"

        {:ok, context}
      end
    end
  end
end
