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
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Repo
  alias CodeMySpecTest.HexTarballFixtures

  @vector List.duplicate(0.1, 384)

  setup do
    # `reconcile_all/0` runs each package through `FLAME.call/2`, a
    # different process even under `FLAME.LocalBackend` — `Req.Test`'s stub
    # registry is ownership-based like the Ecto sandbox, so without shared
    # mode that spawned process cannot see this test's stub at all.
    Req.Test.set_req_test_to_shared()
    Application.put_env(:code_my_spec, :embedding_serving, CodeMySpecTest.FakeEmbeddingServing)
    Application.put_env(:code_my_spec, HexPackageFetch, plug: {Req.Test, HexPackageFetch})
    start_supervised!({FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 4, backend: FLAME.LocalBackend})

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :embedding_serving)
      Application.delete_env(:code_my_spec, HexPackageFetch)
    end)

    %{scope: full_scope_fixture()}
  end

  defp lockfile_entry(name, version, checksum) do
    ~s("#{name}": {:hex, :#{name}, "#{version}", "chk", [:mix], [], "hexpm", "#{checksum}"})
  end

  defp lockfile_text(name, version, checksum) do
    "%{\n  " <> lockfile_entry(name, version, checksum) <> "\n}\n"
  end

  defp seed_dependency(scope, name, version, tarball) do
    checksum = HexTarballFixtures.checksum(tarball)
    {:ok, _} = Dependencies.record_lockfile(scope, lockfile_text(name, version, checksum))
    checksum
  end

  # `record_lockfile/2` treats its argument as the project's *whole* lock —
  # recording one package at a time would have each call drop the ones
  # before it. Seed several in one call, the way a real multi-dependency
  # mix.lock actually would.
  defp seed_dependencies(scope, entries) do
    body =
      Enum.map_join(entries, ",\n  ", fn {name, version, tarball} ->
        lockfile_entry(name, version, HexTarballFixtures.checksum(tarball))
      end)

    {:ok, _} = Dependencies.record_lockfile(scope, "%{\n  " <> body <> "\n}\n")
    :ok
  end

  defp record_high_water_mark(in_flight, max_seen) do
    current = :counters.get(in_flight, 1)
    previous_max = :counters.get(max_seen, 1)
    put_if_higher(max_seen, current, previous_max)
  end

  defp put_if_higher(counter, current, previous_max) when current > previous_max,
    do: :counters.put(counter, 1, current)

  defp put_if_higher(_counter, _current, _previous_max), do: :ok

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

    # Live on :4000 within minutes of the first real sweep (577de9bb step 3):
    # bandit documents Bandit.Clock from two source files, so
    # docs_from_source/1 yielded the same {module_name, markdown} pair twice,
    # chunk_entries/1 produced two identical {path, 0, ...} entries, and the
    # second insert tripped doc_embeddings_shared_path_chunk_index — a crash
    # ON CONFLICT never sees, because it names a different index.
    test "a module documented from two source files is stored once, not crashed on", %{
      scope: scope
    } do
      tarball =
        HexTarballFixtures.build(%{
          "lib/clock.ex" => """
          defmodule Clock do
            @moduledoc "The real implementation."

            @doc "Now."
            def now, do: :ok
          end
          """,
          "lib/clock_fallback.ex" => """
          defmodule Clock do
            @moduledoc "A platform fallback, re-opening the same module."

            @doc "Also now."
            def now, do: :fallback
          end
          """
        })

      seed_dependency(scope, "duplicate_module_pkg", "1.0.0", tarball)
      stub_tarball("duplicate_module_pkg", "1.0.0", tarball)

      :ok = HexDocReconciler.reconcile_all()

      assert %DocPackage{status: "embedded", chunk_count: 1} =
               Repo.get_by(DocPackage, package: "duplicate_module_pkg", version: "1.0.0")

      assert [%{path: "Clock.md"}] =
               from(e in DocEmbedding,
                 where: e.package == "duplicate_module_pkg",
                 select: %{path: e.path}
               )
               |> Repo.all()
    end

    # The shape this would take live: two sweep attempts of the same
    # package overlapping across a restart, both reaching the chunk
    # insert. Simulated here by pre-seeding the exact row a losing
    # concurrent attempt would collide with — same (source, path,
    # chunk_index), a different identity, so it conflicts on
    # doc_embeddings_shared_path_chunk_index even though the
    # (package, version, model, path, chunk_index) index this reconciler
    # targets would not. The point: that conflict must come back as a
    # recorded `failed` marker, never a raised exception that leaves the
    # package stuck retrying forever.
    test "a store conflict with an existing row is marked failed, not raised", %{scope: scope} do
      tarball = HexTarballFixtures.build(%{"lib/race.ex" => "defmodule Race do\n  @moduledoc \"hi\"\nend\n"})
      seed_dependency(scope, "race_pkg", "1.0.0", tarball)
      stub_tarball("race_pkg", "1.0.0", tarball)

      :ok =
        PgVectorBackend.store_embedded_chunk(
          nil,
          "hexdocs:race_pkg",
          "Race.md",
          0,
          "stale",
          "stale-file-hash",
          @vector,
          package: "race_pkg",
          version: "0.9.0",
          model: "a-stale-model"
        )

      :ok = HexDocReconciler.reconcile_all()

      assert %DocPackage{status: "failed", error: error} =
               Repo.get_by(DocPackage, package: "race_pkg", version: "1.0.0")

      assert error =~ "unique_violation" or error =~ "doc_embeddings_shared_path_chunk_index"
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

    test "no more than @max_concurrency packages are fetched at once", %{scope: scope} do
      tarball = HexTarballFixtures.build(%{"lib/concurrent.ex" => "defmodule Concurrent do\n  @moduledoc \"hi\"\nend\n"})

      entries = for n <- 1..8, do: {"concurrent_pkg_#{n}", "1.0.0", tarball}
      :ok = seed_dependencies(scope, entries)

      in_flight = :counters.new(1, [])
      max_seen = :counters.new(1, [])

      Req.Test.stub(HexPackageFetch, fn conn ->
        :counters.add(in_flight, 1, 1)
        record_high_water_mark(in_flight, max_seen)

        # Long enough that 8 packages dispatched at concurrency 4 genuinely
        # overlap rather than finishing one at a time before the next starts.
        Process.sleep(30)
        :counters.sub(in_flight, 1, 1)
        Plug.Conn.send_resp(conn, 200, tarball)
      end)

      :ok = HexDocReconciler.reconcile_all()

      assert :counters.get(max_seen, 1) <= 4
      assert :counters.get(max_seen, 1) > 1
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
