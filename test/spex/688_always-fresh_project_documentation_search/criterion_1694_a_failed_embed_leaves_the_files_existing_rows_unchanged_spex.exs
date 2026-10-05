defmodule CodeMySpecSpex.Story688.Criterion1694Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1694 — A failed embed leaves the file's existing rows unchanged.

  A model that is down for a moment should not cost a project its search.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessedKnowledgeHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    dir = CodeMySpec.TempFile.owned_dir("test")
    :ok = Fixtures.embed_on_pgvector(dir)
    :ok
  end

  spex "A failed embed keeps what search had", criterion: 1694 do
    scenario "a file is edited while embedding fails" do
      given_ "a searchable knowledge file is edited while embedding is failing", context do
        main = checkout(context, main?: true)
        harness_up(main)
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres.")
        manifest(main)
        :ok = Fixtures.fail_embedding(true)
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres with pgvector.")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest", context do
        manifest(context.main)
        {:ok, context}
      end

      then_ "search still has the earlier version", context do
        text = search(context.main, "project_knowledge")
        assert text =~ "We chose Postgres."
        refute text =~ "pgvector"
        {:ok, context}
      end
    end
  end
end
