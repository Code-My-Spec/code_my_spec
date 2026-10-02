defmodule CodeMySpecSpex.Story688.Criterion1690Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1690 — A knowledge file removed from the main copy leaves search.

  A record someone deleted should stop being cited.
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

  spex "A removed knowledge file leaves search", criterion: 1690 do
    scenario "a decision record is deleted on the main copy" do
      given_ "the main copy's two knowledge files are searchable", context do
        main = checkout(context, main?: true)
        harness_up(main)
        write_knowledge(main, "keep.md", "# Keep\n\nWe chose Postgres.")
        write_knowledge(main, "gone.md", "# Gone\n\nWe once chose MySQL.")
        manifest(main)
        assert knowledge_found(main) == ["gone.md", "keep.md"]
        remove_knowledge(main, "gone.md")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest", context do
        manifest(context.main)
        {:ok, context}
      end

      then_ "search no longer finds the removed file", context do
        assert knowledge_found(context.main) == ["keep.md"]
        refute search(context.main, "project_knowledge") =~ "MySQL"
        {:ok, context}
      end
    end
  end
end
