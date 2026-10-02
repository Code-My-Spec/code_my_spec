defmodule CodeMySpecSpex.Story688.Criterion1691Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1691 — An unchanged knowledge file is not read or embedded again, and a
  changed one re-embeds only that file.

  Every manifest re-reading every file would move the whole knowledge base
  over the wire for each edit.
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

  spex "Only the changed knowledge file is read and embedded", criterion: 1691 do
    scenario "one of two files is edited" do
      given_ "two knowledge files are searchable, and one is then edited", context do
        main = checkout(context, main?: true)
        harness_up(main)
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres.")
        write_knowledge(main, "ui.md", "# UI\n\nWe chose DaisyUI.")
        manifest(main)
        _ = {reads(), embedded()}
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres with pgvector.")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest", context do
        manifest(context.main)
        {:ok, Map.merge(context, %{reads: reads(), embedded: embedded()})}
      end

      then_ "only the edited file was read and embedded", context do
        assert context.reads == [".code_my_spec/knowledge/db.md"]
        assert [_ | _] = context.embedded
        assert Enum.all?(context.embedded, &(&1 =~ "pgvector")), inspect(context.embedded)
        {:ok, context}
      end

      then_ "search has the edit and still finds the other file", context do
        assert search(context.main, "project_knowledge") =~ "pgvector"
        assert knowledge_found(context.main) == ["db.md", "ui.md"]
        {:ok, context}
      end
    end
  end
end
