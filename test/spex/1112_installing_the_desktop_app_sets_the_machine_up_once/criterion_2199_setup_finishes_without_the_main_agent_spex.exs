defmodule CodeMySpecSpex.Story1112.Criterion2199Spex do
  @moduledoc "A fresh desktop user with no connected agent provider can finish machine setup unaided."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Setup can be finished without the main agent", criterion: 2199 do
    scenario "No agent provider is connected but manual setup remains usable" do
      given_ "a fresh desktop user has no connected agent provider and an existing Elixir project",
             context do
        project_dir = Path.join(context.machine_root, "unaided_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(project_dir, "mix.exs"),
            """
            defmodule UnaidedApp.MixProject do
              use Mix.Project
              def project, do: [app: :unaided_app, version: "0.1.0", deps: []]
              def application, do: []
            end
            """
          )

        {:ok, view, _} = live(context.conn, "/app")
        render_async(view, 10_000)
        {:ok, Map.merge(context, %{view: view, project_dir: project_dir})}
      end

      then_ "setup reports unavailable agent help and still offers manual checks", context do
        assert has_element?(context.view, "[data-test='setup-agent-unavailable']")
        assert has_element?(context.view, "[data-test='check-prerequisites']:not([disabled])")

        refute has_element?(
                 context.view,
                 "[data-test='setup-agent-help']"
               )

        {:ok, context}
      end

      when_ "the developer checks prerequisites without asking an agent", context do
        context.view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "the outcomes are readable and linking remains available", context do
        assert has_element?(context.view, "[data-test='setup-agent-unavailable']")
        assert has_element?(context.view, "[data-test='setup-results-file'][data-path]")
        assert has_element?(context.view, "[data-test='link-project-form']")
        assert read_machine_file!(context, context.command_log) =~ ~r/^psql /m
        {:ok, context}
      end

      when_ "the developer links the project and finishes setup manually", context do
        context.view
        |> form("[data-test='link-project-form']", project: %{path: context.project_dir})
        |> render_submit()

        render_async(context.view, 10_000)

        [project_id] =
          context.view
          |> element("[data-test='project-connected']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-project-id")

        result = context.view |> element("[data-test='finish-setup']") |> render_click()
        assert {:error, {:live_redirect, %{to: path}}} = result
        assert path == "/app/projects/#{project_id}/agent-conversation"
        {:ok, destination, _} = follow_redirect(result, context.conn)
        render_async(destination, 10_000)
        {:ok, Map.merge(context, %{destination: destination, project_id: project_id})}
      end

      then_ "machine setup is complete and the connected project reaches the cockpit", context do
        assert has_element?(context.destination, "[data-test='conversation-layout']")
        assert has_element?(context.destination, "[data-test='desktop-setup-results']")

        refute has_element?(
                 context.destination,
                 "[data-test='desktop-setup'][data-stage='prerequisites']"
               )

        [path] =
          context.destination
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

        assert String.starts_with?(Path.expand(path), Path.expand(context.machine_root) <> "/")
        assert read_machine_file!(context, path) =~ ~r/pgvector/i

        assert {:ok, _source} =
                 Environments.read_file(
                   context.machine_environment,
                   Path.join(context.project_dir, "mix.exs")
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
