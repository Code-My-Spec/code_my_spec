defmodule CodeMySpecSpex.Story1112.Criterion2198Spex do
  @moduledoc "Explicit project linking still refuses non-Elixir directories."
  use CodeMySpecSpex.Case, async: false

  spex "Linking a project that is not an Elixir project is refused", criterion: 2198 do
    scenario "An ordinary directory cannot be linked" do
      given_ "a directory containing only an HTML file", context do
        root = CmsHarnessTest.SetupFixture.non_elixir_project()
        {:ok, Map.put(context, :root, root)}
      end

      then_ "linking refuses it without modifying the directory", context do
        assert {:error, {:invalid_elixir_project, _, :enoent}} =
                 CmsHarnessTest.SetupFixture.connect_project(context.root, %{}, [])

        assert CmsHarnessTest.SetupFixture.directory_contents(context.root) == %{
                 "index.html" => "<h1>Site</h1>"
               }

        {:ok, context}
      end
    end
  end
end
