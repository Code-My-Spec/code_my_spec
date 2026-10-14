defmodule CodeMySpecSpex.Story1064.Criterion2200Spex do
  @moduledoc """
  Story 1064 — The product agent onboards me
  Criterion 2200 — A developer who finishes the desktop app's machine setup and
  creates or links a project lands in the onboarding conversation, with the
  form beside it already showing what setup just created or linked.

  ## Reusing story 1112's own handoff

  Criterion 2039 (story 1112) already drives this exact handoff — link a
  project through the desktop app's `/app` flow, finish setup, and land on
  `/app/projects/\#{project_id}/agent-conversation` — and already asserts the
  landing page carries `conversation-layout` and the recorded
  `desktop-setup-results`. This spex reuses that same drive (the given,
  `DesktopSetupHelpers.fresh_machine`, and the same button sequence) rather
  than inventing a second one: "setup hands off into the interview" and
  "setup hands off to the standard interview" are the same event seen from
  two different stories' acceptance criteria.

  What this spex checks, specifically for this criterion's own `criterion:`
  binding: the destination is the project's own conversation, and the panel
  beside it already shows what setup just created or linked — not just that
  a panel exists.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "a developer finishes desktop setup having created or linked a project",
    criterion: 2200 do
    scenario "Desktop setup hands off into the interview" do
      given_ "a developer has finished the desktop app's machine setup and created or linked a project",
             context do
        project_dir = Path.join(context.machine_root, "handoff_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule HandoffApp.MixProject do
              use Mix.Project
              def project, do: [app: :handoff_app, version: "0.1.0", deps: []]
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

        [project_id] =
          view
          |> element("[data-test='project-connected']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-project-id")

        {:ok, context |> Map.put(:view, view) |> Map.put(:project_id, project_id)}
      end

      when_ "setup hands off", context do
        result = context.view |> element("[data-test='finish-setup']") |> render_click()
        {:error, {:live_redirect, %{to: destination}}} = result

        {:ok, interview, _html} = follow_redirect(result, context.conn)
        render_async(interview, 10_000)

        {:ok, context |> Map.put(:interview, interview) |> Map.put(:destination, destination)}
      end

      then_ "they are in the onboarding conversation, with the form beside it", context do
        assert context.destination == "/app/projects/#{context.project_id}/agent-conversation",
               "setup handed off somewhere other than the project's own conversation"

        assert has_element?(context.interview, "[data-test='conversation-layout']"),
               "there is no conversation on the page setup handed off to"

        {:ok, context}
      end

      and_ "the form already shows the project setup created or linked", context do
        assert has_element?(context.interview, "[data-test='desktop-setup-results']"),
               """
               The panel beside the conversation says nothing about what was just
               created or linked. It is not paperwork showing setup's own outcome
               if it is empty of it.
               """

        {:ok, context}
      end
    end
  end
end
