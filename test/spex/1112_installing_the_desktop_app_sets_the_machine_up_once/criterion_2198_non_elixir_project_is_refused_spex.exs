defmodule CodeMySpecSpex.Story1112.Criterion2198Spex do
  @moduledoc "Explicit project linking still refuses non-Elixir directories."
  use CodeMySpecSpex.Case, async: false

  spex "Linking a project that is not an Elixir project is refused", criterion: 2198 do
    scenario "An ordinary directory cannot be linked" do
      given_ "a directory containing only an HTML file", context do
        root =
          Path.join(System.tmp_dir!(), "invalid-project-#{System.unique_integer([:positive])}")

        File.mkdir_p!(root)
        File.write!(Path.join(root, "index.html"), "<h1>Site</h1>")
        on_exit(fn -> File.rm_rf!(root) end)
        {:ok, Map.put(context, :root, root)}
      end

      then_ "linking refuses it without modifying the directory", context do
        assert {:error, {:invalid_elixir_project, _, :enoent}} =
                 CmsHarnessTest.SetupFixture.connect_project(context.root, %{}, [])

        assert File.ls!(context.root) == ["index.html"]
        assert File.read!(Path.join(context.root, "index.html")) == "<h1>Site</h1>"
        {:ok, context}
      end
    end
  end
end
