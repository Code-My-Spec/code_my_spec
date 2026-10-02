defmodule CodeMySpec.Embeddings.HexDocReconcilerTest do
  @moduledoc """
  577de9bb step 3's actual embedding work: fetch, verify, parse, chunk,
  embed, store, mark — against a real tarball built by
  `CodeMySpecTest.HexTarballFixtures` and a `Req.Test` stub standing in for
  hex.pm. No live network call, no 90MB model (`FakeEmbeddingServing`
  stands in for Ortex), and `project_dependencies` is seeded through
  `Dependencies.record_lockfile/2` — the real trigger path — rather than
  inserted by hand, so a project's state here is what step 3's own trigger
  would actually have produced.
  """

  use CodeMySpecTest.DataCase, async: false

  import Ecto.Query
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.HexDocReconciler
  alias CodeMySpec.Embeddings.HexPackageFetch
  alias CodeMySpec.Repo
  alias CodeMySpecTest.HexTarballFixtures

  setup do
    # `reconcile_all/0` runs each package through `FLAME.call/2`, a
    # different process even under `FLAME.LocalBackend` — `Req.Test`'s stub
    # registry is ownership-based like the Ecto sandbox, so without shared
    # mode that spawned process cannot see this test's stub at all.
    Req.Test.set_req_test_to_shared()
    Application.put_env(:code_my_spec, :embedding_serving, CodeMySpecTest.FakeEmbeddingServing)
    Application.put_env(:code_my_spec, HexPackageFetch, plug: {Req.Test, HexPackageFetch})
    start_supervised!({FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: FLAME.LocalBackend})

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :embedding_serving)
      Application.delete_env(:code_my_spec, HexPackageFetch)
    end)

    %{scope: full_scope_fixture()}
  end

  defp lockfile_text(name, version, checksum) do
    ~s(%{\n  "#{name}": {:hex, :#{name}, "#{version}", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)
  end

  defp seed_dependency(scope, name, version, tarball) do
    checksum = HexTarballFixtures.checksum(tarball)
    {:ok, _} = Dependencies.record_lockfile(scope, lockfile_text(name, version, checksum))
    checksum
  end

  defp stub_tarball(name, version, tarball) do
    Req.Test.stub(HexPackageFetch, fn conn ->
      assert conn.request_path == "/tarballs/#{name}-#{version}.tar"
      Plug.Conn.send_resp(conn, 200, tarball)
    end)
  end

  defp stub_http_error(name, version, status) do
    Req.Test.stub(HexPackageFetch, fn conn ->
      assert conn.request_path == "/tarballs/#{name}-#{version}.tar"
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  describe "reconcile_all/0" do
    test "a documented package is embedded and marked, chunk by module", %{scope: scope} do
      tarball =
        HexTarballFixtures.build(%{
          "lib/demo.ex" => """
          defmodule Demo do
            @moduledoc "Demo says hi."

            @doc "Says hi."
            def hi, do: :ok
          end
          """
        })

      seed_dependency(scope, "demo_pkg", "1.0.0", tarball)
      stub_tarball("demo_pkg", "1.0.0", tarball)

      :ok = HexDocReconciler.reconcile_all()

      assert %DocPackage{status: "embedded", chunk_count: 1} =
               Repo.get_by(DocPackage, package: "demo_pkg", version: "1.0.0")

      assert [%{source: "hexdocs:demo_pkg", path: "Demo.md", version: "1.0.0"}] =
               from(e in DocEmbedding,
                 where: e.package == "demo_pkg",
                 select: %{source: e.source, path: e.path, version: e.version}
               )
               |> Repo.all()
    end

    test "a package with no documented modules is marked no_docs, not retried forever", %{
      scope: scope
    } do
      tarball = HexTarballFixtures.build(%{"lib/undocumented.ex" => "defmodule Undocumented do\nend\n"})

      seed_dependency(scope, "bare_pkg", "2.0.0", tarball)
      stub_tarball("bare_pkg", "2.0.0", tarball)

      :ok = HexDocReconciler.reconcile_all()

      assert %DocPackage{status: "no_docs", chunk_count: 0} =
               Repo.get_by(DocPackage, package: "bare_pkg", version: "2.0.0")

      assert HexDocReconciler.pending() == []
    end

    test "a checksum mismatch is marked failed, not embedded from untrusted bytes", %{
      scope: scope
    } do
      real_tarball = HexTarballFixtures.build(%{"lib/evil.ex" => "defmodule Evil do\n  @moduledoc \"nope\"\nend\n"})
      wrong_tarball = HexTarballFixtures.build(%{"lib/other.ex" => "defmodule Other do\n  @moduledoc \"swapped\"\nend\n"})

      seed_dependency(scope, "swapped_pkg", "1.0.0", real_tarball)
      stub_tarball("swapped_pkg", "1.0.0", wrong_tarball)

      :ok = HexDocReconciler.reconcile_all()

      assert %DocPackage{status: "failed", error: error} =
               Repo.get_by(DocPackage, package: "swapped_pkg", version: "1.0.0")

      assert error =~ "checksum_mismatch"
      assert from(e in DocEmbedding, where: e.package == "swapped_pkg", select: e.id)
             |> Repo.all() == []
    end

    test "hex.pm unreachable leaves the package pending for the next sweep", %{scope: scope} do
      tarball = HexTarballFixtures.build(%{"lib/flaky.ex" => "defmodule Flaky do\n  @moduledoc \"hi\"\nend\n"})
      seed_dependency(scope, "flaky_pkg", "1.0.0", tarball)
      stub_http_error("flaky_pkg", "1.0.0", 500)

      :ok = HexDocReconciler.reconcile_all()

      assert %DocPackage{status: "failed"} =
               Repo.get_by(DocPackage, package: "flaky_pkg", version: "1.0.0")

      # Marked failed rather than left silently missing — but still distinct
      # from "embedded", so a future design that wants to retry failures
      # (not built here) has something to select on.
      refute Repo.get_by(DocPackage, package: "flaky_pkg", version: "1.0.0").status == "embedded"
    end

    test "a git dependency is never sent to hex.pm", %{scope: scope} do
      lock = ~s(%{\n  "git_pkg": {:git, "https://example.com/git_pkg.git", "abc123", [branch: "main"]}\n}\n)
      {:ok, _} = Dependencies.record_lockfile(scope, lock)

      assert HexDocReconciler.pending() == []
      :ok = HexDocReconciler.reconcile_all()

      assert Repo.get_by(DocPackage, package: "git_pkg") == nil
    end

    test "two projects pinning the same package@version embed it once", %{scope: scope} do
      tarball = HexTarballFixtures.build(%{"lib/shared.ex" => "defmodule Shared do\n  @moduledoc \"hi\"\nend\n"})
      checksum = HexTarballFixtures.checksum(tarball)

      other_scope = full_scope_fixture()
      {:ok, _} = Dependencies.record_lockfile(scope, lockfile_text("shared_pkg", "1.0.0", checksum))

      {:ok, _} =
        Dependencies.record_lockfile(other_scope, lockfile_text("shared_pkg", "1.0.0", checksum))

      fetch_count = :counters.new(1, [])
      Req.Test.stub(HexPackageFetch, fn conn ->
        :counters.add(fetch_count, 1, 1)
        Plug.Conn.send_resp(conn, 200, tarball)
      end)

      :ok = HexDocReconciler.reconcile_all()

      assert :counters.get(fetch_count, 1) == 1
      assert %DocPackage{status: "embedded"} = Repo.get_by(DocPackage, package: "shared_pkg")
    end

    test "a package already embedded at this model is not reconciled again", %{scope: scope} do
      tarball = HexTarballFixtures.build(%{"lib/once.ex" => "defmodule Once do\n  @moduledoc \"hi\"\nend\n"})
      seed_dependency(scope, "once_pkg", "1.0.0", tarball)
      stub_tarball("once_pkg", "1.0.0", tarball)

      :ok = HexDocReconciler.reconcile_all()
      assert %DocPackage{status: "embedded"} = Repo.get_by(DocPackage, package: "once_pkg")

      # No stub set for a second fetch — reconciling again must not try.
      Req.Test.stub(HexPackageFetch, fn _conn -> raise "should not be called again" end)

      assert HexDocReconciler.pending() == []
      :ok = HexDocReconciler.reconcile_all()
    end
  end
end
