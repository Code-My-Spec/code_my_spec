defmodule CodeMySpecSpex.Story688.Criterion1688Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1688 — A knowledge file added on the project's main copy is read through its
  harness, embedded, and found by search.

  The server has no checkout: it learns a file changed from the harness's
  manifest and reads the content back over the same harness.
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

  spex "A knowledge file on the main copy becomes searchable", criterion: 1688 do
    scenario "the main copy's harness reports a new decision record" do
      given_ "the main copy has a new knowledge file and its harness is up", context do
        main = checkout(context, main?: true)
        harness_up(main)
        write_knowledge(main, "decisions.md", "# Decisions\n\nWe chose Postgres for search.")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest", context do
        manifest(context.main)
        {:ok, context}
      end

      then_ "the server read the file over the harness", context do
        assert ".code_my_spec/knowledge/decisions.md" in reads()
        {:ok, context}
      end

      then_ "and search finds it", context do
        assert knowledge_found(context.main) == ["decisions.md"]
        assert search(context.main, "project_knowledge") =~ "We chose Postgres for search."
        {:ok, context}
      end
    end
  end
end
