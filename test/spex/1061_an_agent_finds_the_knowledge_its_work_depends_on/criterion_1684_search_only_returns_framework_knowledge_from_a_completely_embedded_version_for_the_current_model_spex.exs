defmodule CodeMySpecSpex.Story1061.Criterion1684Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1684 — Search only returns framework knowledge from a completely embedded
  version for the current model.

  Vectors from another model live in a different space; comparing a query
  against them returns noise that looks like an answer.
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

  spex "Search uses only the current model's knowledge", criterion: 1684 do
    scenario "the embedding model changes" do
      given_ "knowledge embedded with one model, and the server now runs another", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")
        :ok = Fixtures.server_starts()
        assert knowledge_paths(context.scope) == ["liveview.md"]
        :ok = Fixtures.switch_embedding_model("another-model")
        {:ok, context}
      end

      when_ "an agent searches before the new model has embedded it", context do
        {:ok, Map.put(context, :before, knowledge_paths(context.scope))}
      end

      then_ "the old model's rows are not returned", context do
        assert context.before == [],
               "search returned rows embedded with another model: #{inspect(context.before)}"

        {:ok, context}
      end

      when_ "the server starts and embeds it with the new model", context do
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "search finds it again", context do
        assert knowledge_paths(context.scope) == ["liveview.md"]
        {:ok, context}
      end
    end
  end

  spex "Search never returns a version that failed to finish", criterion: 1684 do
    scenario "embedding a new version fails" do
      given_ "a release adds a file and embedding it fails", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")
        :ok = Fixtures.server_starts()
        Fixtures.write_framework_knowledge_file(dir, "new.md", "# New\n\nNew advice.")
        :ok = Fixtures.fail_embedding(true)
        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "search returns the complete earlier version and nothing of the unfinished one",
            context do
        assert knowledge_paths(context.scope) == ["liveview.md"]
        {:ok, context}
      end
    end
  end
end
