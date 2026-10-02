defmodule CodeMySpecSpex.Story1061.Criterion1685Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1685 — If embedding framework knowledge fails partway, the previous version
  stays searchable and the next start finishes the work.

  A failed embed must not leave agents with nothing to search, and must not
  need anyone to notice it and run something.
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

  spex "A failed embed keeps the old version and finishes next start", criterion: 1685 do
    scenario "the model is down when a release changes a file, then comes back" do
      given_ "a release changes a file while embedding is failing", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")
        :ok = Fixtures.server_starts()

        Fixtures.write_framework_knowledge_file(
          dir,
          "liveview.md",
          "# LiveView\n\nUse assign_async/3 for async data."
        )

        :ok = Fixtures.fail_embedding(true)
        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "search still has the previous version", context do
        text = knowledge_text(context.scope)
        assert text =~ "Use assign/2."
        refute text =~ "assign_async"
        {:ok, context}
      end

      when_ "embedding works again and the server starts", context do
        :ok = Fixtures.fail_embedding(false)
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "search has the new version", context do
        text = knowledge_text(context.scope)
        assert text =~ "assign_async"
        refute text =~ "Use assign/2."
        {:ok, context}
      end
    end
  end
end
