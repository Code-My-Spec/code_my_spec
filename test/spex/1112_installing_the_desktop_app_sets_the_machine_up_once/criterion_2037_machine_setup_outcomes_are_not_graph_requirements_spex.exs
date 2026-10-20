defmodule CodeMySpecSpex.Story1112.Criterion2037Spex do
  @moduledoc "Machine setup records history without becoming recurring graph work."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers
  alias CodeMySpecSpex.GraphAssertions

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Recorded machine setup is not re-evaluated after a machine change", criterion: 2037 do
    scenario "Completed setup remains historical when pgvector is later removed" do
      given_ "setup has run its steps and linked an existing Elixir project", context do
        project_dir = Path.join(context.machine_root, "existing_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule ExistingApp.MixProject do
              use Mix.Project
              def project, do: [app: :existing_app, version: "0.1.0", deps: []]
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
           recorded_results: read_machine_file!(context, results_path),
           recorded_commands: read_machine_file!(context, context.command_log)
         })}
      end

      then_ "every setup step shows its recorded outcome and when it ran", context do
        assert has_element?(
                 context.view,
                 "[data-test='setup-step'][data-step='pgvector'][data-state='done'] time[datetime]"
               )

        rows =
          render(context.view)
          |> Floki.parse_fragment!()
          |> Floki.find("[data-test='setup-step']")

        assert length(rows) >= 6

        Enum.each(rows, fn row ->
          assert [state] = Floki.attribute(row, "data-state")
          assert state == "done"
          assert [timestamp] = row |> Floki.find("time[datetime]") |> Floki.attribute("datetime")
          assert {:ok, _, _} = DateTime.from_iso8601(timestamp)
        end)

        assert context.recorded_results =~ ~r/pgvector/i
        assert context.recorded_commands != ""
        {:ok, context}
      end

      when_ "the developer removes pgvector and later opens the project requirements", context do
        DesktopSetupHelpers.without_pgvector(context)

        {:ok, _view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project_id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the populated graph contains no machine setup requirement or offer", context do
        nodes = Enum.map(context.graph["nodes"], & &1["attributes"])
        assert nodes != []

        refute Enum.any?(nodes, &(&1["entity_type"] == "machine"))

        refute Enum.any?(
                 nodes,
                 &Regex.match?(
                   ~r/(machine.*setup|setup.*machine|prerequisite|pgvector)/i,
                   to_string(&1["name"])
                 )
               )

        {:ok, context}
      end

      then_ "recorded outcomes stay unchanged and no prerequisite command runs again", context do
        assert read_machine_file!(context, context.results_path) == context.recorded_results
        assert read_machine_file!(context, context.command_log) == context.recorded_commands

        assert has_element?(
                 context.view,
                 "[data-test='setup-step'][data-step='pgvector'][data-state='done']"
               )

        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
