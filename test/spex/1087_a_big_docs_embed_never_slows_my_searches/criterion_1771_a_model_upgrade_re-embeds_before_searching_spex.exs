defmodule CodeMySpecSpex.Story1087.Criterion1771Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1771 — A model upgrade re-embeds before searching.

  Search and document vectors must come from the same model and version.
  After a model change, a query against the new model must not be compared
  against documents still carrying the old one; the old docs disappear from
  results until the new model re-embeds them.
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
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @lib %{"lib/swept.ex" => "defmodule Swept do\n  @moduledoc \"Swept sweeps the floor.\"\nend\n"}

  defp lock(checksum),
    do:
      ~s(%{\n  "swept_pkg": {:hex, :swept_pkg, "1.0.0", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)

  spex "Docs re-embed under a new model before a search can use them", criterion: 1771 do
    scenario "the server moves from model A to model B" do
      given_ "swept_pkg's docs are embedded with model A", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(@lib)

        Req.Test.stub(
          CodeMySpec.Embeddings.HexPackageFetch,
          &Plug.Conn.send_resp(&1, 200, tarball)
        )

        :ok = Fixtures.switch_embedding_model("model-a")
        write_lock(main, lock(checksum))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "Swept sweeps the floor."
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the server moves to model B and an agent searches before it re-embeds", context do
        :ok = Fixtures.switch_embedding_model("model-b")
        {:ok, Map.put(context, :before_reembed, search(context.main, "hexdocs"))}
      end

      then_ "no search compares a model B query against model A's documents", context do
        refute context.before_reembed =~ "Swept sweeps the floor."
        {:ok, context}
      end

      when_ "the docs are re-embedded with model B", context do
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, context}
      end

      then_ "search finds them again, now under model B", context do
        assert search(context.main, "hexdocs") =~ "Swept sweeps the floor."
        {:ok, context}
      end
    end
  end
end
