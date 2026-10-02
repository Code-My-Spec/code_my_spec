defmodule CodeMySpecSpex.Story688.Criterion1693Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1693 — With the main copy's harness offline, a knowledge file keeps its
  existing rows and is embedded once the harness is back.

  The server can only read a file through the harness. While it cannot,
  the last good version is still worth finding, and nobody should have to
  notice and re-run anything.
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

  spex "An offline harness defers the update and loses nothing", criterion: 1693 do
    scenario "a file changes while the main copy's harness drops" do
      given_ "a searchable knowledge file, edited while the harness goes offline", context do
        main = checkout(context, main?: true)
        harness = harness_up(main)
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres.")
        manifest(main)
        :ok = harness_down(harness)
        write_knowledge(main, "db.md", "# Database\n\nWe chose Postgres with pgvector.")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the manifest carrying the edit arrives", context do
        manifest(context.main)
        {:ok, context}
      end

      then_ "search still has the earlier version", context do
        text = search(context.main, "project_knowledge")
        assert text =~ "We chose Postgres."
        refute text =~ "pgvector"
        {:ok, context}
      end

      when_ "the harness is back and the sweep runs", context do
        harness_up(context.main)
        :ok = Fixtures.lockfile_sweep_runs()
        {:ok, context}
      end

      then_ "search has the edit", context do
        assert search(context.main, "project_knowledge") =~ "pgvector"
        {:ok, context}
      end
    end
  end
end
