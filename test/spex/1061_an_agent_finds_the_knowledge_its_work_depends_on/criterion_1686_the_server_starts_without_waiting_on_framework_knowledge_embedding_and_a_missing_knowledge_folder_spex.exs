defmodule CodeMySpecSpex.Story1061.Criterion1686Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1686 — The server starts without waiting on framework knowledge embedding,
  and a missing knowledge folder does not stop it.

  Embedding is background work. A server that cannot start until it finishes,
  or at all without a knowledge folder, has made search a dependency of
  everything else.
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

  spex "Starting does not depend on embedding", criterion: 1686 do
    scenario "the knowledge folder is missing" do
      given_ "the release has no knowledge folder", context do
        :ok = Fixtures.embed_on_pgvector(Path.join(knowledge_folder(), "absent"))
        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "search answers, with nothing to find", context do
        assert knowledge_paths(context.scope) == []
        assert knowledge_text(context.scope) =~ "No matches found"
        {:ok, context}
      end
    end

    scenario "embedding fails at start" do
      given_ "the release has knowledge and the model is down", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")
        :ok = Fixtures.fail_embedding(true)
        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "the start completes and search still answers", context do
        assert knowledge_text(context.scope) =~ "Search:"
        {:ok, context}
      end
    end
  end
end
