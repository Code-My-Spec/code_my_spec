defmodule CodeMySpecSpex.Story1087.Criterion1772Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1772 — A lost burst box resumes where it stopped.

  A bulk embedding job may not finish in one pass. What already finished
  must not be redone, and what didn't must still get done.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessedKnowledgeHelpers
  import ExUnit.CaptureLog

  alias CodeMySpec.Embeddings.InFlightCalls
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    dir = CodeMySpec.TempFile.owned_dir("test")
    :ok = Fixtures.embed_on_pgvector(dir)
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @pkg_a %{
    "lib/pkg_a.ex" =>
      "defmodule PkgA do\n  @moduledoc \"PkgA finished before the box died.\"\nend\n"
  }
  @pkg_b %{
    "lib/pkg_b.ex" =>
      "defmodule PkgB do\n  @moduledoc \"PkgB was still unembedded when the box died.\"\nend\n"
  }

  # Hex-doc embeddings carry no `project_id` — they're global knowledge, not
  # scoped to whichever project's sweep happened to embed them first. Pkg_a
  # and pkg_b are already embedded (by the scenario above) for the rest of
  # this test, so the real-kill scenario needs its own, never-touched
  # packages or its own sweep would find nothing pending at all.
  @pkg_c %{
    "lib/pkg_c.ex" =>
      "defmodule PkgC do\n  @moduledoc \"PkgC finished before the runner was killed.\"\nend\n"
  }
  @pkg_d %{
    "lib/pkg_d.ex" =>
      "defmodule PkgD do\n  @moduledoc \"PkgD was still unembedded when the runner was killed.\"\nend\n"
  }

  # Same reasoning as pkg_c/pkg_d — fresh names so this scenario's own sweep
  # has real pending work of its own.
  @pkg_e %{
    "lib/pkg_e.ex" =>
      "defmodule PkgE do\n  @moduledoc \"PkgE finished before the caller died.\"\nend\n"
  }
  @pkg_f %{
    "lib/pkg_f.ex" =>
      "defmodule PkgF do\n  @moduledoc \"PkgF was still embedding when the caller died.\"\nend\n"
  }

  defp lock(entries) do
    body =
      Enum.map_join(entries, ",\n  ", fn {name, version, checksum} ->
        ~s("#{name}": {:hex, :#{name}, "#{version}", "chk", [:mix], [], "hexpm", "#{checksum}"})
      end)

    "%{\n  #{body}\n}\n"
  end

  defp serve(tarballs) do
    Req.Test.stub(CodeMySpec.Embeddings.HexPackageFetch, fn conn ->
      [_, name] = Regex.run(~r/([a-z_]+)-[^-]+\.tar$/, conn.request_path)
      Plug.Conn.send_resp(conn, 200, Map.fetch!(tarballs, name))
    end)
  end

  # A duplicate row reads as the same result block appearing twice in a
  # search — checking that off the surface rather than `doc_embeddings`
  # directly, same reasoning as every other assertion in this file.
  defp count_occurrences(text, marker),
    do: text |> String.split(marker) |> length() |> Kernel.-(1)

  # The real-kill scenario below deliberately crashes a Task — a genuine
  # `[error]` log is the expected shape of that failure mode, not a sign
  # something went wrong unobserved.
  spex "A lost burst box resumes embedding where it stopped",
    criterion: 1772,
    fail_on_error_logs: false do
    scenario "half a docs set was embedded when the burst box died" do
      given_ "pkg_a finished embedding before the box died, and pkg_b had not started",
             context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball_a, checksum_a} = Fixtures.hex_tarball(@pkg_a)
        {tarball_b, checksum_b} = Fixtures.hex_tarball(@pkg_b)
        serve(%{"pkg_a" => tarball_a, "pkg_b" => tarball_b})

        write_lock(main, lock([{"pkg_a", "1.0.0", checksum_a}]))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "PkgA finished before the box died."
        _ = embedded()

        write_lock(
          main,
          lock([{"pkg_a", "1.0.0", checksum_a}, {"pkg_b", "1.0.0", checksum_b}])
        )

        manifest(main)
        :ok = Fixtures.fail_embedding(true)
        :ok = Fixtures.hex_doc_sweep_runs()
        _ = embedded()
        {:ok, Map.put(context, :main, main)}
      end

      when_ "embedding resumes", context do
        :ok = Fixtures.fail_embedding(false)
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, Map.put(context, :resumed_batches, embedded())}
      end

      then_ "only the unembedded half is embedded", context do
        assert Enum.any?(context.resumed_batches, &(&1 =~ "PkgB was still unembedded")),
               "expected pkg_b to be embedded on resume, got: #{inspect(context.resumed_batches)}"

        {:ok, context}
      end

      then_ "the already-embedded half is not redone", context do
        refute Enum.any?(context.resumed_batches, &(&1 =~ "PkgA finished before the box died.")),
               "pkg_a was re-embedded on resume: #{inspect(context.resumed_batches)}"

        assert search(context.main, "hexdocs") =~ "PkgA finished before the box died."
        assert search(context.main, "hexdocs") =~ "PkgB was still unembedded"
        {:ok, context}
      end
    end

    # The scenario above fakes the failure at the serving boundary — a real
    # dispatch through `FLAME.Pool`, but an injected `{:error, :serving_down}`
    # return rather than anything actually dying. This scenario kills the
    # real process `RecordingEmbeddingServing.embed_batch/2` runs in while a
    # batch is in flight — the same shape of loss a live Hetzner burst box
    # dying mid-build would hand back to `InFlightCalls.call/3` (confirmed
    # directly against a real box tonight; `in_flight_calls_test.exs` proves
    # the counter side of this at the unit level). Both are real failure
    # modes this story has to survive, so both stay.
    scenario "the burst box's own runner process is killed mid-batch" do
      given_ "pkg_c finished embedding, and the next batch will block until released",
             context do
        # Independent of the scenario above and its own `fail_embedding`
        # toggle — never assume the order scenarios run in left this clean.
        :ok = Fixtures.fail_embedding(false)

        main = checkout(context, main?: true)
        harness_up(main)
        {tarball_c, checksum_c} = Fixtures.hex_tarball(@pkg_c)
        {tarball_d, checksum_d} = Fixtures.hex_tarball(@pkg_d)
        serve(%{"pkg_c" => tarball_c, "pkg_d" => tarball_d})

        write_lock(main, lock([{"pkg_c", "1.0.0", checksum_c}]))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "PkgC finished before the runner was killed."
        _ = embedded()

        write_lock(
          main,
          lock([{"pkg_c", "1.0.0", checksum_c}, {"pkg_d", "1.0.0", checksum_d}])
        )

        manifest(main)
        Fixtures.pause_embedding_until_released(true)
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the sweep runs and pkg_d's real runner is killed while its batch is in flight",
            context do
        # `spawn_monitor/1`, not `Task.async/1` — the sweep is *not* linked to
        # this test process. `reconcile_one/1` calls `FLAME.call` with no
        # `:link` override, so FLAME's own default links the runner to its
        # caller; killing the runner is meant to crash something inside the
        # reconcile pipeline for real, and this test should observe that
        # outcome rather than be dragged down by it if the crash turns out
        # to reach further than `reconcile_all/0`'s own per-package
        # isolation is supposed to contain.
        capture_log(fn ->
          {sweep_pid, sweep_ref} = spawn_monitor(fn -> Fixtures.hex_doc_sweep_runs() end)

          assert_receive {:runner_pid, runner_pid}, 5_000
          Process.exit(runner_pid, :lost_connection)
          Fixtures.pause_embedding_until_released(false)

          assert_receive {:DOWN, ^sweep_ref, :process, ^sweep_pid, _reason}, :timer.seconds(30)
        end)

        {:ok, context}
      end

      then_ "nothing is left stuck in flight on the pool", context do
        refute InFlightCalls.any_in_flight?(CodeMySpec.EmbedPool),
               "the in-flight count never came back down after the runner was killed"

        {:ok, context}
      end

      when_ "the sweep runs again", context do
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, context}
      end

      then_ "pkg_d is embedded on resume and neither package is duplicated", context do
        text = search(context.main, "hexdocs")

        assert text =~ "PkgC finished before the runner was killed."
        assert text =~ "PkgD was still unembedded"

        assert count_occurrences(text, "**hexdocs:pkg_c/PkgC.md**") == 1,
               "pkg_c's own chunk does not appear exactly once: #{text}"

        assert count_occurrences(text, "**hexdocs:pkg_d/PkgD.md**") == 1,
               "pkg_d's chunk does not appear exactly once — duplicated on resume: #{text}"

        {:ok, context}
      end
    end

    # `InFlightCalls.call/3` now forces `link: false` (the fix above) so a
    # dead runner can't take its caller down with it. That trade has a
    # mirror image worth proving on its own: if the *caller* dies instead —
    # the reconciler's own task crashing, a node restart mid-call — the
    # runner is no longer linked to it either, so it keeps running with
    # nobody left to hand its result to. Harness's own question: is that
    # harmless? This proves it is — the runner finishes and exits on its
    # own (no leak), its write already landed by the time anyone looks
    # (nothing was lost), and a later sweep finds nothing left to do
    # (idempotent, not redone).
    scenario "the reconciler's own caller dies, but the runner it started keeps working" do
      given_ "pkg_e finished embedding, and the next batch will block until released",
             context do
        :ok = Fixtures.fail_embedding(false)

        main = checkout(context, main?: true)
        harness_up(main)
        {tarball_e, checksum_e} = Fixtures.hex_tarball(@pkg_e)
        {tarball_f, checksum_f} = Fixtures.hex_tarball(@pkg_f)
        serve(%{"pkg_e" => tarball_e, "pkg_f" => tarball_f})

        write_lock(main, lock([{"pkg_e", "1.0.0", checksum_e}]))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "PkgE finished before the caller died."
        _ = embedded()

        write_lock(
          main,
          lock([{"pkg_e", "1.0.0", checksum_e}, {"pkg_f", "1.0.0", checksum_f}])
        )

        manifest(main)
        Fixtures.pause_embedding_until_released(true)
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the sweep's own caller is killed while pkg_f's runner is still mid-batch",
            context do
        capture_log(fn ->
          {sweep_pid, sweep_ref} = spawn_monitor(fn -> Fixtures.hex_doc_sweep_runs() end)

          assert_receive {:runner_pid, runner_pid}, 5_000
          runner_ref = Process.monitor(runner_pid)

          Process.exit(sweep_pid, :kill)
          assert_receive {:DOWN, ^sweep_ref, :process, ^sweep_pid, _reason}, 5_000

          # The one claim this scenario exists to check: the caller dying
          # does not take the runner with it — the opposite direction from
          # the scenario above, now that `link: false` cuts both ways.
          refute_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _}, 200

          Fixtures.release_embedding(runner_pid)

          assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}, 5_000

          assert reason in [:normal, :shutdown],
                 "the orphaned runner did not exit cleanly on its own: #{inspect(reason)}"
        end)

        {:ok, context}
      end

      then_ "pkg_f's own write already landed — nothing was lost", context do
        assert search(context.main, "hexdocs") =~ "PkgF was still embedding when the caller died."

        {:ok, context}
      end

      when_ "a later sweep runs with no caller left orphaned", context do
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, context}
      end

      then_ "neither package was redone or duplicated", context do
        text = search(context.main, "hexdocs")

        assert count_occurrences(text, "**hexdocs:pkg_e/PkgE.md**") == 1,
               "pkg_e's own chunk does not appear exactly once: #{text}"

        assert count_occurrences(text, "**hexdocs:pkg_f/PkgF.md**") == 1,
               "pkg_f's chunk does not appear exactly once — the later sweep redid it: #{text}"

        {:ok, context}
      end
    end
  end
end
