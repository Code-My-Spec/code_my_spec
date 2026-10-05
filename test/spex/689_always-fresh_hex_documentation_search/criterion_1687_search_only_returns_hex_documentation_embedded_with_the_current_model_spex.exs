defmodule CodeMySpecSpex.Story689.Criterion1687Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search.
  Criterion 1687 — Search only returns hex documentation embedded with the current model.

  A model change makes every stored vector incomparable with new queries.
  Hex docs re-embed under the new model; until then they are not returned.
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
    # hex.pm is fetched inside the embed pool, not this process.
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @lib %{"lib/swept.ex" => "defmodule Swept do\n  @moduledoc \"Swept sweeps the floor.\"\nend\n"}

  defp lock(checksum),
    do:
      ~s(%{\n  "swept_pkg": {:hex, :swept_pkg, "1.0.0", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)

  spex "Hex docs follow the current model", criterion: 1687 do
    scenario "the embedding model changes after a package was embedded" do
      given_ "swept_pkg's docs were embedded with an older model", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(@lib)

        Req.Test.stub(
          CodeMySpec.Embeddings.HexPackageFetch,
          &Plug.Conn.send_resp(&1, 200, tarball)
        )

        :ok = Fixtures.switch_embedding_model("older-model")
        write_lock(main, lock(checksum))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "Swept sweeps the floor."
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the server now embeds with another model, and an agent searches", context do
        :ok = Fixtures.switch_embedding_model("fake-test-model")
        {:ok, Map.put(context, :text, search(context.main, "hexdocs"))}
      end

      then_ "the older model's hex docs are not returned", context do
        refute context.text =~ "Swept sweeps the floor."
        {:ok, context}
      end
    end
  end
end
