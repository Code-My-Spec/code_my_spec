defmodule CodeMySpecSpex.Story1061.Criterion1681Spex do
  @moduledoc """
  Story 1061 — An agent finds the knowledge its work depends on.
  Criterion 1681 — A restart with no knowledge changed embeds nothing.

  Knowledge only changes with a release, so most starts have nothing to do,
  and doing it anyway would spend minutes of embedding on every restart.
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

  spex "A restart with nothing changed embeds nothing", criterion: 1681 do
    scenario "the server restarts on the same release" do
      given_ "the server started once and embedded the knowledge", context do
        dir = knowledge_folder()
        :ok = Fixtures.embed_on_pgvector(dir)
        Fixtures.write_framework_knowledge_file(dir, "liveview.md", "# LiveView\n\nUse assign/2.")
        :ok = Fixtures.server_starts()
        assert [_ | _] = embedded_texts()
        {:ok, context}
      end

      when_ "it starts again with the same knowledge", context do
        :ok = Fixtures.server_starts()
        {:ok, Map.put(context, :embedded, embedded_texts())}
      end

      then_ "nothing is embedded, and search still finds the knowledge", context do
        assert context.embedded == [], "a restart re-embedded: #{inspect(context.embedded)}"
        assert knowledge_paths(context.scope) == ["liveview.md"]
        {:ok, context}
      end
    end
  end
end
