defmodule CodeMySpecSpex.Story1112.Criterion2039Spex do
  @moduledoc "Desktop setup hands its connected project and recorded results to the cockpit."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Completed desktop setup opens the connected project's cockpit", criterion: 2039 do
    scenario "A linked project and setup results reach the cockpit without sign-in" do
      given_ "the desktop has checked prerequisites and linked an Elixir project", context do
        project_dir = Path.join(context.machine_root, "interview_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule InterviewApp.MixProject do
              use Mix.Project
              def project, do: [app: :interview_app, version: "0.1.0", deps: []]
              def application, do: []
            end
            """
          )

        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)

        [results_path] =
          view
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

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

        {:ok,
         Map.merge(context, %{
           view: view,
           project_id: project_id,
           results_path: results_path,
           recorded_results: read_machine_file!(context, results_path)
         })}
      end

      when_ "the developer finishes machine setup", context do
        refute has_element?(context.view, "[data-test='intake-transcript']")
        refute has_element?(context.view, "form[phx-submit='answer']")
        result = context.view |> element("[data-test='finish-setup']") |> render_click()
        assert {:error, {:live_redirect, %{to: destination}}} = result
        assert destination == "/app/projects/#{context.project_id}/agent-conversation"
        {:ok, interview, _html} = follow_redirect(result, context.conn)
        render_async(interview, 10_000)
        {:ok, Map.put(context, :interview, interview)}
      end

      then_ "the cockpit is open for the project setup connected", context do
        assert has_element?(context.interview, "[data-test='conversation-layout']")
        assert has_element?(context.interview, "[data-test='desktop-setup-results']")
        refute has_element?(context.interview, "form[action='/users/log_in']")
        refute has_element?(context.interview, "form[action='/users/register']")
        {:ok, context}
      end

      then_ "the cockpit retains access to the recorded setup outcome", context do
        assert has_element?(
                 context.interview,
                 "[data-test='setup-results-file'][data-path='#{context.results_path}']"
               )

        assert read_machine_file!(context, context.results_path) == context.recorded_results
        assert context.recorded_results =~ ~r/pgvector/i
        assert has_element?(context.interview, "[data-test='desktop-setup-results']", "pgvector")
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
