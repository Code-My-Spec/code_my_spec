defmodule CodeMySpecSpex.Story1061.Criterion1682Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1682 — Changing one framework knowledge file re-embeds only that file.

  A release that edits one page should cost one page of embedding.
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

  spex "One changed file is the only one embedded again", criterion: 1682 do
    scenario "a release changes one of three files" do
      given_ "the server embedded three files, and a new release changes one", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")

        Fixtures.write_framework_knowledge_file(
          dir,
          "daisyui.md",
          "# DaisyUI\n\nUse btn classes."
        )

        Fixtures.write_framework_knowledge_file(dir, "ecto.md", "# Ecto\n\nUse changesets.")
        :ok = Fixtures.server_starts()
        _first = embedded_texts()

        Fixtures.write_framework_knowledge_file(
          dir,
          "liveview.md",
          "# LiveView\n\nUse assign_async/3 for async data."
        )

        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, Map.put(context, :embedded, embedded_texts())}
      end

      then_ "only the changed file was embedded", context do
        assert [_ | _] = context.embedded
        assert Enum.all?(context.embedded, &(&1 =~ "assign_async")), inspect(context.embedded)
        {:ok, context}
      end

      then_ "search has its new content and still finds the other two", context do
        text = knowledge_text(context.scope)
        assert text =~ "assign_async"
        refute text =~ "Use assign/2."
        assert knowledge_paths(context.scope) == ["daisyui.md", "ecto.md", "liveview.md"]
        {:ok, context}
      end
    end
  end
end
