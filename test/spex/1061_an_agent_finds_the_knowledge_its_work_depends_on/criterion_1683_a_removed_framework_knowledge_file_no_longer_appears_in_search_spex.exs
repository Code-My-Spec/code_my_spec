defmodule CodeMySpecSpex.Story1061.Criterion1683Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1683 — A removed framework knowledge file no longer appears in search.

  A page the release no longer ships is advice nobody stands behind.
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

  spex "A removed file leaves search", criterion: 1683 do
    scenario "a release drops one of two files" do
      given_ "the server embedded two files, and a new release drops one", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")
        Fixtures.write_framework_knowledge_file(dir, "retired.md", "# Retired\n\nOld advice.")
        :ok = Fixtures.server_starts()
        assert knowledge_paths(context.scope) == ["liveview.md", "retired.md"]
        File.rm!(Path.join(dir, "retired.md"))
        {:ok, context}
      end

      when_ "the server starts", context do
        :ok = Fixtures.server_starts()
        {:ok, context}
      end

      then_ "search no longer finds the removed file", context do
        assert knowledge_paths(context.scope) == ["liveview.md"]
        refute knowledge_text(context.scope) =~ "Old advice."
        {:ok, context}
      end
    end
  end
end
