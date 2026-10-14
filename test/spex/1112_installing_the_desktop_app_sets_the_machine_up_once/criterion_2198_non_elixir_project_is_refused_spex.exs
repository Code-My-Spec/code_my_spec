defmodule CodeMySpecSpex.Story1112.Criterion2198Spex do
  @moduledoc "Linking rejects a non-Elixir directory and permits correcting the selection."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Linking a project that is not an Elixir project is refused", criterion: 2198 do
    scenario "The developer corrects a directory selection after a clear refusal" do
      given_ "prerequisites pass and the developer has a non-Elixir directory and an Elixir project",
             context do
        invalid = Path.join(context.machine_root, "plain_site")
        valid = Path.join(context.machine_root, "elixir_app")

        :ok =
          Environments.write_file(
            context.machine_environment,
            Path.join(invalid, "index.html"),
            "<h1>Existing site</h1>"
          )

        :ok =
          Environments.write_file(context.machine_environment, Path.join(valid, "mix.exs"), """
          defmodule ElixirApp.MixProject do
            use Mix.Project
            def project, do: [app: :elixir_app, version: "0.1.0", deps: []]
            def application, do: []
          end
          """)

        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)
        {:ok, Map.merge(context, %{view: view, invalid: invalid, valid: valid})}
      end

      when_ "the developer tries to link the directory without mix.exs", context do
        context.view
        |> form("[data-test='link-project-form']", project: %{path: context.invalid})
        |> render_submit()

        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "setup explains the refusal and keeps project selection available", context do
        assert has_element?(context.view, "[data-test='link-project-error']")

        error =
          context.view
          |> element("[data-test='link-project-error']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert error =~ ~r/Elixir|mix\.exs/i

        assert has_element?(
                 context.view,
                 "[data-test='link-project-form'] input[name='project[path]']"
               )

        assert has_element?(context.view, "[data-test='create-project-form']")
        refute has_element?(context.view, "[data-test='project-connected']")

        refute Environments.file_exists?(
                 context.machine_environment,
                 Path.join(context.invalid, "mix.exs")
               )

        assert read_machine_file!(context, Path.join(context.invalid, "index.html")) ==
                 "<h1>Existing site</h1>"

        {:ok, context}
      end

      when_ "the developer selects the existing Elixir project instead", context do
        context.view
        |> form("[data-test='link-project-form']", project: %{path: context.valid})
        |> render_submit()

        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "the valid project connects without restarting setup", context do
        assert has_element?(
                 context.view,
                 "[data-test='project-connected'][data-path='#{context.valid}']",
                 "elixir_app"
               )

        assert has_element?(context.view, "[data-test='project-connected'] a[href]")

        refute has_element?(
                 context.view,
                 "[data-test='project-connected'][data-path='#{context.invalid}']"
               )

        refute has_element?(context.view, "[data-test='link-project-error']")
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
