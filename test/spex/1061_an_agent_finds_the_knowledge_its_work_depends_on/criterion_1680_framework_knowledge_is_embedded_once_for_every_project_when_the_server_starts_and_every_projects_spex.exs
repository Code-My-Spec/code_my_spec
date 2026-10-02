defmodule CodeMySpecSpex.Story1061.Criterion1680Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1680 — Framework knowledge is embedded once for every project when the
  server starts, and every project's search finds it.

  The release ships the same knowledge to everyone, so it is embedded once,
  as shared rows, rather than once per project.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.KnowledgeSearchHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Framework knowledge is embedded once and found by every project", criterion: 1680 do
    scenario "the server starts with two knowledge files" do
      given_ "the release ships two knowledge files", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")

        Fixtures.write_framework_knowledge_file(
          dir,
          "daisyui.md",
          "# DaisyUI\n\nUse btn classes."
        )

        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, Map.put(context, :embedded, embedded_texts())}
      end

      then_ "each file was embedded once", context do
        assert Enum.count(context.embedded, &(&1 =~ "assign/2")) == 1, inspect(context.embedded)

        assert Enum.count(context.embedded, &(&1 =~ "btn classes")) == 1,
               inspect(context.embedded)

        {:ok, context}
      end

      then_ "this project's search finds both", context do
        assert knowledge_paths(context.scope) == ["daisyui.md", "liveview.md"]
        {:ok, context}
      end

      then_ "another project's search finds both too, with nothing more embedded", context do
        assert knowledge_paths(another_project(context)) == ["daisyui.md", "liveview.md"]
        assert embedded_texts() == []
        {:ok, context}
      end
    end
  end
end
