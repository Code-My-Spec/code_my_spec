defmodule CodeMySpecSpex.Story1002.Criterion1918Spex do
  @moduledoc """
  Story 1002 — Model and system share one analysis run record.
  Criterion 1918 — An analysis run and its clear-then-insert reconcile
  complete in a supervised background task independent of whoever started
  it, and the reconcile is atomic.

  `Analysis.Reconciler`'s own moduledoc: "Runs inside the analysis Task,
  never a GenServer callback or an HTTP request, so an aborted hook request
  cannot strand a half-written reconcile." `ensure_stale_runs/3` is the
  entry point that promise rests on — it "returns immediately; jobs run in
  the background and reconcile Problems as they land." This drives it
  directly through `Fixtures.land_outputs/2`, the same fixture `end_turn`
  uses to pre-populate analyzer output, without its optional `:await` — so
  nothing in either scenario ever waits on the run it starts. Completion is
  only ever observed afterwards, through `list_problems`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @fixture_dir "test/fixtures/validation"
  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The reconcile runs inside its own Task, a different process than the
    # one calling `land_outputs/2` below — `:shared` is what lets that task
    # use this test's own sandboxed connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An analysis run and its clear-then-insert reconcile complete in a supervised background task independent of whoever started it, and the reconcile is atomic",
    criterion: 1918 do
    scenario "a compiler run reconciles on its own, with nothing left to drive it forward" do
      given_ "analysis runs asynchronously, in its own supervised background task", context do
        {:ok, Map.put(context, :restore_mode, async_mode())}
      end

      when_ "a dirty compiler run is requested and the caller does not wait on it", context do
        use_cmd_cassette "pipeline_compile_error", record: :none do
          Fixtures.land_outputs(context.scope,
            compile_output_file: fixture_path("pipeline_compile_error/compile.jsonl")
          )
        end

        {:ok, context}
      end

      then_ "the finding lands anyway, through the run's own background task", context do
        assert Fixtures.poll_until(fn ->
                 compiler_problems(context.scope) =~ "lib/example_context.ex"
               end) ==
                 :ok,
               "the compiler finding never reconciled, though nothing ever asked it to wait — " <>
                 "a reconcile that depends on its caller still being there is not independent " <>
                 "of whoever started it"

        {:ok, context}
      end
    end

    scenario "a second, clean run replaces the first run's findings wholesale" do
      given_ "analysis runs asynchronously, in its own supervised background task", context do
        {:ok, Map.put(context, :restore_mode, async_mode())}
      end

      given_ "a prior dirty compiler run has already reconciled", context do
        use_cmd_cassette "pipeline_compile_error", record: :none do
          Fixtures.land_outputs(context.scope,
            compile_output_file: fixture_path("pipeline_compile_error/compile.jsonl")
          )
        end

        Fixtures.poll_until(fn ->
          compiler_problems(context.scope) =~ "lib/example_context.ex"
        end)

        {:ok, context}
      end

      when_ "a clean compiler run is requested next, and the caller again does not wait",
            context do
        use_cmd_cassette "clean", record: :none do
          Fixtures.land_outputs(context.scope,
            compile_output_file: fixture_path("pipeline_clean_run/compile.jsonl")
          )
        end

        {:ok, context}
      end

      then_ "the stale finding is gone, not merely joined by the clean result", context do
        assert Fixtures.poll_until(fn -> compiler_problems(context.scope) =~ "No problems" end) ==
                 :ok,
               "the first run's finding outlived the second run's reconcile — a clear-then-insert " <>
                 "that is not atomic leaves the old and the new mixed, or neither, for a window " <>
                 "a reader can observe"

        {:ok, context}
      end
    end
  end

  # Flips `:analysis_mode` to `:async` for the duration of this test — the
  # test env default (`:inline`) runs `ensure_stale_runs/3` in the calling
  # process itself, which would make "nothing waits on it" trivially true
  # for the wrong reason.
  defp async_mode do
    previous = Application.get_env(:code_my_spec, :analysis_mode)
    Application.put_env(:code_my_spec, :analysis_mode, :async)
    on_exit(fn -> Application.put_env(:code_my_spec, :analysis_mode, previous) end)
    previous
  end

  defp compiler_problems(scope) do
    {:ok, text} = ToolLibrary.run("list_problems", %{"source" => "compiler"}, %{scope: scope})
    text
  end
end
