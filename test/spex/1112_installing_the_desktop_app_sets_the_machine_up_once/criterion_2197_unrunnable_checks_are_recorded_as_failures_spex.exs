defmodule CodeMySpecSpex.Story1112.Criterion2197Spex do
  @moduledoc "Missing executables and unsuccessful commands cannot produce passing prerequisite checks."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "A check command that cannot run is recorded as a failure", criterion: 2197 do
    scenario "The machine has no Vibium executable and cms cannot start" do
      given_ "Vibium is absent and the installed cms executable reports a startup error",
             context do
        bin = Path.join(context.machine_root, "bin")
        :ok = Environments.delete_file(context.machine_environment, Path.join(bin, "vibium"))

        :ok =
          Environments.write_file(context.machine_environment, Path.join(bin, "cms"), """
          #!/bin/sh
          printf 'cms runtime cannot load required library\\n' >&2
          exit 126
          """)

        {:ok, view, _} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the developer runs the prerequisite checks", context do
        context.view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "both checks are failed and their reasons are visible", context do
        for name <- ["cms", "vibium"] do
          assert has_element?(
                   context.view,
                   "[data-test='prerequisite'][data-name='#{name}'][data-state='failed']"
                 )

          refute has_element?(
                   context.view,
                   "[data-test='prerequisite'][data-name='#{name}'][data-state='done']"
                 )
        end

        cms =
          context.view
          |> element("[data-test='prerequisite'][data-name='cms']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        vibium =
          context.view
          |> element("[data-test='prerequisite'][data-name='vibium']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert cms =~ "cms runtime cannot load required library"
        assert vibium =~ ~r/not found|enoent|no such file|could not find/i
        {:ok, context}
      end

      then_ "the results file records the failures and setup cannot advance", context do
        [path] =
          context.view
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

        assert String.starts_with?(Path.expand(path), Path.expand(context.machine_root) <> "/")
        results = read_machine_file!(context, path)
        assert results =~ "cms runtime cannot load required library"
        assert results =~ "126"
        assert results =~ ~r/vibium/i
        assert results =~ ~r/not found|enoent|no such file|could not find/i

        assert has_element?(
                 context.view,
                 "[data-test='desktop-setup'][data-stage='prerequisites']"
               )

        refute has_element?(context.view, "[data-test='create-project']:not([disabled])")
        refute has_element?(context.view, "[data-test='project-connected']")
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
