defmodule CodeMySpecSpex.Story688.Criterion1689Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search.
  Criterion 1689 — Knowledge files on a copy that is not the main copy are not embedded.

  The project's knowledge is the main copy's. A feature branch's notes are
  work in progress, and searching them would mix drafts into the record.
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

  spex "Only the main copy's knowledge is embedded", criterion: 1689 do
    scenario "a feature copy reports a knowledge file" do
      given_ "a project with a main copy, and a feature copy holding a knowledge file", context do
        _main = checkout(context, main?: true)
        feature = checkout(context)
        harness_up(feature)
        write_knowledge(feature, "draft.md", "# Draft\n\nMaybe we use Redis.")
        {:ok, Map.put(context, :feature, feature)}
      end

      when_ "the feature copy's harness sends its manifest", context do
        manifest(context.feature)
        {:ok, context}
      end

      then_ "nothing is read or embedded, and search does not find it", context do
        assert reads() == []
        assert embedded() == []
        assert knowledge_found(context.feature) == []
        {:ok, context}
      end
    end
  end
end
