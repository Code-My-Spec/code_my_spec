defmodule CodeMySpec.Validation.FailedRerunNoteTest do
  @moduledoc """
  `fa6d31bf`. Compiler's newest run failed behind an older completed answer, so
  a "cannot satisfy its own mix.lock" finding stayed live after `mix deps.get`
  fixed it, with nothing saying the rerun had failed.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{Reconciler, RunsRepository}
  alias CodeMySpec.Problems.{Problem, ProblemRenderer}
  alias CodeMySpec.Validation

  setup do
    %{scope: full_scope_fixture()}
  end

  defp start(scope) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: "compiler", kind: :full, args: %{"args" => []}})

    run
  end

  defp completed(scope) do
    {:ok, _} = RunsRepository.finish_run(start(scope), :completed, %{exit_status: 0})
  end

  defp failed(scope, reason) do
    {:ok, _} = Reconciler.fail(start(scope), reason)
  end

  defp render(scope) do
    problem = %Problem{
      source: "compiler",
      severity: :error,
      file_path: "mix.lock",
      line: 1,
      message: "This checkout cannot satisfy its own mix.lock"
    }

    ProblemRenderer.render_stop_response([problem], [],
      failed_reruns: Validation.failed_reruns(scope, ["compiler"])
    )
  end

  test "a failed run newer than the answer is named, with its reason", %{scope: scope} do
    completed(scope)
    failed(scope, "compiler crashed: port closed before the build finished")

    text = render(scope)

    assert text =~ "Latest compiler run failed at"
    assert text =~ "port closed before the build finished"

    assert text =~ "were not re-checked",
           "the findings are from the older answer; saying nothing made a fixed " <>
             "finding look current"
  end

  test "a completed newest run adds no note", %{scope: scope} do
    failed(scope, "compiler crashed: port closed")
    completed(scope)

    refute render(scope) =~ "Latest compiler run failed"
  end
end
