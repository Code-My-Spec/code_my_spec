defmodule CodeMySpecSpex.Story688.Criterion1692Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1692 — Search returns project knowledge only for the current model, and
  knowledge from an older model is re-embedded.

  Vectors from another model are in another space. Until the file is
  re-embedded, it is better unfound than found by accident.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessedKnowledgeHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    {:ok, dir} = Briefly.create(directory: true)
    :ok = Fixtures.embed_on_pgvector(dir)
    :ok
  end

  spex "Project knowledge follows the current model", criterion: 1692 do
    scenario "the embedding model changes" do
      given_ "a knowledge file embedded with an older model", context do
        main = checkout(context, main?: true)
        harness_up(main)
        :ok = Fixtures.switch_embedding_model("older-model")
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres.")
        manifest(main)
        :ok = Fixtures.switch_embedding_model("fake-test-model")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "an agent searches before anything re-embeds it", context do
        {:ok, Map.put(context, :before, knowledge_found(context.main))}
      end

      then_ "the older model's rows are not returned", context do
        assert context.before == []
        {:ok, context}
      end

      when_ "the sweep runs", context do
        :ok = Fixtures.lockfile_sweep_runs()
        {:ok, context}
      end

      then_ "the unchanged file is re-embedded and found", context do
        assert knowledge_found(context.main) == ["db.md"]
        {:ok, context}
      end
    end
  end
end
