defmodule CodeMySpec.Embeddings.HexDocSweepTest do
  @moduledoc """
  `sweep_now/0` is a thin driver over `HexDocReconciler.reconcile_all/0` —
  the reconcile behavior itself (success, failure, idempotence) is
  `hex_doc_reconciler_test.exs`'s job. What's worth proving here is that
  this thin layer actually wires up: calling it drives a real pending
  package all the way to `embedded`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.HexDocSweep
  alias CodeMySpec.Embeddings.HexPackageFetch
  alias CodeMySpec.Repo
  alias CodeMySpecTest.HexTarballFixtures

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:code_my_spec, :embedding_serving, CodeMySpecTest.FakeEmbeddingServing)
    Application.put_env(:code_my_spec, HexPackageFetch, plug: {Req.Test, HexPackageFetch})

    start_supervised!(
      {FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: FLAME.LocalBackend}
    )

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :embedding_serving)
      Application.delete_env(:code_my_spec, HexPackageFetch)
    end)

    %{scope: full_scope_fixture()}
  end

  test "drives a pending package to embedded", %{scope: scope} do
    tarball =
      HexTarballFixtures.build(%{
        "lib/swept.ex" => "defmodule Swept do\n  @moduledoc \"hi\"\nend\n"
      })

    checksum = HexTarballFixtures.checksum(tarball)

    lock =
      ~s(%{\n  "swept_pkg": {:hex, :swept_pkg, "1.0.0", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)

    {:ok, _} = Dependencies.record_lockfile(scope, lock)
    Req.Test.stub(HexPackageFetch, fn conn -> Plug.Conn.send_resp(conn, 200, tarball) end)

    assert :ok = HexDocSweep.sweep_now()

    assert %DocPackage{status: "embedded"} =
             Repo.get_by(DocPackage, package: "swept_pkg", version: "1.0.0")
  end

  test "nothing pending is a quiet no-op" do
    assert :ok = HexDocSweep.sweep_now()
  end
end
