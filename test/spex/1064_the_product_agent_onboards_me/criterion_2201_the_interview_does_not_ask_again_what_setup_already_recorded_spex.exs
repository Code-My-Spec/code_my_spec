defmodule CodeMySpecSpex.Story1064.Criterion2201Spex do
  @moduledoc """
  Story 1064 — The product agent onboards me
  Criterion 2201 — The onboarding interview a desktop setup hands off into does
  not ask the developer to create or link a project again, and does not ask
  them to sign up.

  ## Same handoff, different half of the same event

  Criterion 2200 (this story) and criterion 2039 (story 1112) both drive this
  handoff; this spex drives it again rather than asserting on the one those
  already produce, because a spec file's binding is the `criterion:` tag on
  its own `spex` block, not a shared fixture result — "does not ask again" is
  its own acceptance criterion with its own scenario.

  "It does not ask them to sign up" is checked by the absence of both the
  registration and login forms — criterion 2039 already established this is
  the case under story 1112's own wording ("without sign-in"); this checks it
  again under 1064's wording so that this criterion, not only 2039's, has a
  spec that would catch a regression.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "desktop setup has already recorded the project and its location",
    criterion: 2201 do
    scenario "The interview does not ask again what setup already recorded" do
      given_ "desktop setup has recorded the project and its location", context do
        project_dir = Path.join(context.machine_root, "recorded_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule RecordedApp.MixProject do
              use Mix.Project
              def project, do: [app: :recorded_app, version: "0.1.0", deps: []]
              def application, do: []
            end
            """
          )

        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)

        view
        |> form("[data-test='link-project-form']", project: %{path: project_dir})
        |> render_submit()

        render_async(view, 10_000)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the onboarding interview starts", context do
        result = context.view |> element("[data-test='finish-setup']") |> render_click()
        {:ok, interview, _html} = follow_redirect(result, context.conn)
        render_async(interview, 10_000)

        {:ok, Map.put(context, :interview, interview)}
      end

      then_ "it does not ask the developer to create or link a project again", context do
        refute has_element?(context.interview, "[data-test='link-project-form']"),
               """
               The interview is asking the developer to create or link a project,
               having just created or linked one on the previous page. Desktop
               setup already recorded it; asking again throws that work away.
               """

        {:ok, context}
      end

      and_ "it does not ask them to sign up, because the desktop app has no sign-in", context do
        refute has_element?(context.interview, "form[action='/users/register']"),
               "the interview put a signup form in front of a developer who arrived with no sign-in at all"

        refute has_element?(context.interview, "form[action='/users/log_in']"),
               "the interview put a login form in front of a developer who arrived with no sign-in at all"

        {:ok, context}
      end
    end
  end
end
