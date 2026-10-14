defmodule CodeMySpecSpex.Story1112.Criterion2040Spex do
  @moduledoc "Opening the desktop preserves completed setup; another run requires an explicit action."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Setup runs again only when the developer asks to set up a project", criterion: 2040 do
    scenario "Reopening is passive and an explicit setup can check the machine again" do
      given_ "machine setup has completed for an existing Elixir project", context do
        project_dir = Path.join(context.machine_root, "completed_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule CompletedApp.MixProject do
              use Mix.Project
              def project, do: [app: :completed_app, version: "0.1.0", deps: []]
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

        result = view |> element("[data-test='finish-setup']") |> render_click()
        {:ok, interview, _} = follow_redirect(result, context.conn)
        render_async(interview, 10_000)

        {:ok,
         Map.merge(context, %{
           results_path: results_path,
           recorded_results: read_machine_file!(context, results_path),
           recorded_commands: read_machine_file!(context, context.command_log)
         })}
      end

      when_ "pgvector is removed and the developer reopens the desktop", context do
        DesktopSetupHelpers.without_pgvector(context)
        {:ok, reopened, _} = live(context.conn, "/app")
        render_async(reopened, 10_000)
        {:ok, Map.put(context, :reopened, reopened)}
      end

      then_ "opening the app performs no setup and preserves the recorded outcome", context do
        assert context.recorded_commands != ""
        assert has_element?(context.reopened, "[data-test='set-up-project']")

        refute has_element?(
                 context.reopened,
                 "[data-test='desktop-setup'][data-stage='prerequisites']"
               )

        assert read_machine_file!(context, context.command_log) == context.recorded_commands
        assert read_machine_file!(context, context.results_path) == context.recorded_results
        {:ok, context}
      end

      when_ "the developer explicitly chooses to set up a project and checks prerequisites",
            context do
        context.reopened |> element("[data-test='set-up-project']") |> render_click()
        render_async(context.reopened, 10_000)
        context.reopened |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(context.reopened, 10_000)
        {:ok, context}
      end

      then_ "a new check observes the missing prerequisite", context do
        assert has_element?(
                 context.reopened,
                 "[data-test='desktop-setup'][data-stage='prerequisites']"
               )

        assert has_element?(
                 context.reopened,
                 "[data-test='prerequisite'][data-name='pgvector'][data-state='missing']"
               )

        commands = read_machine_file!(context, context.command_log)
        assert String.starts_with?(commands, context.recorded_commands)
        added = String.replace_prefix(commands, context.recorded_commands, "")
        assert added =~ ~r/^psql .*vector/m
        {:ok, context}
      end
    end
  end

  spex "Reopening after the local channel drops reconnects without an explicit action",
    criterion: 2040 do
    scenario "The project reconnects on its own once its channel comes back up" do
      given_ "machine setup has completed and the project is connected", context do
        project_dir = Path.join(context.machine_root, "reconnect_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule ReconnectApp.MixProject do
              use Mix.Project
              def project, do: [app: :reconnect_app, version: "0.1.0", deps: []]
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

        [project_root] =
          view
          |> element("[data-test='project-connected']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

        {:ok, Map.put(context, :project_root, project_root)}
      end

      when_ "the local harness relaunches, leaving the project's channel unstarted", context do
        # The channel-only teardown a relaunch leaves behind: the project's
        # supervisor and registry entry are gone, but nothing on disk (its
        # .cms_harness.json, its served-roots hint) was touched.
        CmsHarnessTest.Projects.stop_project(context.project_root)

        {:ok, reopened, _} = live(context.conn, "/app")
        {:ok, Map.put(context, :reopened, reopened)}
      end

      then_ "the project shows connected again without clicking Check connection", context do
        assert has_element?(
                 context.reopened,
                 "[data-test='project-connected'][data-path='#{context.project_root}']"
               )

        refute has_element?(context.reopened, "[data-test='project-connecting']")
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
