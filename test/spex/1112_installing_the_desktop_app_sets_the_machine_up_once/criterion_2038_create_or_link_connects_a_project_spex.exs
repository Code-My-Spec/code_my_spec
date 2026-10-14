defmodule CodeMySpecSpex.Story1112.Criterion2038Spex do
  @moduledoc "Desktop setup connects a generated or existing Elixir project. The external generator is a filesystem-producing CLI fixture, not a stub of setup or project connection."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Passing prerequisites lets the developer create or link a project", criterion: 2038 do
    scenario "Create a new project through cms new" do
      given_ "every prerequisite has passed on a machine with the generator installed", context do
        context = DesktopSetupHelpers.with_project_generator(context)
        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)
        target = Path.join(context.machine_root, "generated_app")
        {:ok, Map.merge(context, %{view: view, target: target})}
      end

      when_ "the developer creates a new project", context do
        context.view
        |> form("[data-test='create-project-form']",
          project: %{name: "generated_app", path: context.target}
        )
        |> render_submit()

        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "cms new generates the chosen directory and the desktop connects it", context do
        commands = read_machine_file!(context, context.command_log)
        assert commands =~ ~r/^(cms new|mix cms.new) /m
        assert commands =~ context.target

        assert {:ok, _source} =
                 Environments.read_file(
                   context.machine_environment,
                   Path.join(context.target, "mix.exs")
                 )

        assert read_machine_file!(context, Path.join(context.target, "generator-output.txt")) =~
                 "external cms.new fixture"

        assert has_element?(
                 context.view,
                 "[data-test='project-connected'][data-path='#{context.target}']",
                 "generated_app"
               )

        assert has_element?(context.view, "[data-test='project-connected'] a[href]")
        assert_recorded_connection(context)
        {:ok, context}
      end
    end

    scenario "Link an existing Elixir project without regenerating it" do
      given_ "prerequisites have passed and an Elixir project exists on disk", context do
        target = Path.join(context.machine_root, "existing_app")

        source =
          "defmodule ExistingApp.MixProject do\n  use Mix.Project\n  def project, do: [app: :existing_app, version: \"0.1.0\", deps: []]\n  def application, do: []\nend\n"

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(target, "mix.exs"),
            source
          )

        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='set-up-project']") |> render_click()
        render_async(view, 10_000)
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)

        {:ok,
         Map.merge(context, %{
           view: view,
           target: target,
           source: source,
           commands_before: read_machine_file!(context, context.command_log)
         })}
      end

      when_ "the developer links the existing directory", context do
        context.view
        |> form("[data-test='link-project-form']", project: %{path: context.target})
        |> render_submit()

        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "the desktop connects the existing project without running the generator", context do
        assert has_element?(
                 context.view,
                 "[data-test='project-connected'][data-path='#{context.target}']",
                 "existing_app"
               )

        assert has_element?(context.view, "[data-test='project-connected'] a[href]")
        assert_recorded_connection(context)
        assert read_machine_file!(context, Path.join(context.target, "mix.exs")) == context.source
        commands_after = read_machine_file!(context, context.command_log)
        added = String.replace_prefix(commands_after, context.commands_before, "")
        refute added =~ ~r/^(cms new|mix cms.new) /m
        {:ok, context}
      end
    end
  end

  defp assert_recorded_connection(context) do
    [path] =
      context.view
      |> element("[data-test='setup-results-file'][data-path]")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("data-path")

    snapshot = context |> read_machine_file!(path) |> Jason.decode!()
    connection = get_in(snapshot, ["operations", "connect", "result"])
    assert connection["connected"] == true
    assert connection["connection_state"] == "connected"
    assert {:ok, _, _} = DateTime.from_iso8601(connection["observed_at"])
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
