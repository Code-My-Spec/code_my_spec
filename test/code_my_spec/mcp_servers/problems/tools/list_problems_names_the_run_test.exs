defmodule CodeMySpec.McpServers.Problems.Tools.ListProblemsNamesTheRunTest do
  @moduledoc """
  The findings say which run produced them — which database, and how long it
  took.

  Both exist because a finding that is really about the machine is
  indistinguishable from one about the code, and the natural response to each is
  the opposite of the right response to the other.

    * **Which database.** A working copy has three and a run uses one. Twice
      that turned a schema divergence into a phantom regression: 479 spex
      failures naming a column the tree had (`d86b09cd`), and a criterion
      passing sixteen times in isolation while failing every sweep, because a
      foreign key was `CASCADE` on one database and `RESTRICT` on the other
      (`9d4ae2de`).

    * **How long.** On a saturated box the analyzer manufactures failures —
      `** (EXIT from #PID<…>)` on whichever test is heaviest, a different victim
      each sweep, all passing in isolation. Measured at load 54 with eight
      concurrent suites (`3e9b7568`). A sweep that took eight minutes where it
      usually takes ninety seconds is the machine talking, and until now nothing
      said so next to the failures.

  The duration is a proxy for load rather than load itself, and neither of these
  is the machine-wide semaphore `3e9b7568` actually asks for.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.McpServers.Problems.Tools.ListProblems

  setup do
    scope = full_scope_fixture()

    problem_fixture(scope, %{
      file_path: "test/some_test.exs",
      severity: :error,
      source: "exunit",
      message: "** (EXIT from #PID<0.123.0>) an exception was raised"
    })

    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp text(frame) do
    assert {:reply, response, ^frame} = ListProblems.execute(%{}, frame)
    hd(Response.to_protocol(response)["content"])["text"]
  end

  # `finish_run/3` writes `finished_at`; this backdates `started_at` so the run
  # reads as long without the test waiting for one.
  defp finished_run(scope, stats, seconds_long) do
    run = analysis_run_fixture(scope, %{source: "exunit"})
    {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 1, stats: stats})

    started = DateTime.add(run.finished_at, -seconds_long, :second)

    run
    |> Ecto.Changeset.change(started_at: started)
    |> CodeMySpec.Repo.update!()
  end

  test "names the database the run opened", ctx do
    finished_run(ctx.scope, %{"partition" => "h789652afa"}, 5)

    assert text(ctx.frame) =~ "exunit ran against the `h789652afa` test database."
  end

  test "a long run says how long, beside the failures it produced", ctx do
    finished_run(ctx.scope, %{"partition" => "h789652afa"}, 8 * 60 + 13)

    rendered = text(ctx.frame)

    assert rendered =~ "took 8m13s",
           "an EXIT failure from a sweep that ran eight times longer than usual is the " <>
             "machine, and nothing said so"
  end

  # A number on every listing is wallpaper, and the alert next door is
  # counts-only for exactly that reason: a line the model learns to skip costs
  # the signal permanently.
  test "an ordinary run says nothing about its duration", ctx do
    finished_run(ctx.scope, %{"partition" => "h789652afa"}, 12)

    rendered = text(ctx.frame)

    assert rendered =~ "h789652afa"
    refute rendered =~ "took"
  end

  test "a run with no partition still reports a long duration", ctx do
    finished_run(ctx.scope, %{}, 200)

    assert text(ctx.frame) =~ "exunit's run, and took 3m20s."
  end

  test "no run at all adds nothing", ctx do
    assert text(ctx.frame) =~ "test/some_test.exs"
    refute text(ctx.frame) =~ "test database"
  end
end
