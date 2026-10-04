defmodule CodeMySpec.Validation.AStopNeverAnalyzesTest do
  @moduledoc """
  A stop never starts, ingests or waits on analysis (John, 2026-10-04).

  Runs come from `start_analysis`, ready_for_qa certification and promotion. A
  stop reads the problems those runs persisted and may still refuse over
  blocking ones. Recorded analyzer output used to ride along on a stop, which
  made the stop create runs; a caller still passing it now fails loudly rather
  than asserting a block that no longer comes.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Validation

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a stop starts no analysis run", %{scope: scope} do
    before = RunsRepository.latest_full_runs(scope)

    assert {:ok, %{analysis: %{enqueued: []}}} = Validation.validate_stop(scope, nil)
    assert RunsRepository.latest_full_runs(scope) == before
  end

  for opt <- [
        :compile_output_file,
        :credo_output_file,
        :exunit_output_file,
        :spex_output_file,
        :await
      ] do
    test "a stop refuses #{inspect(opt)}", %{scope: scope} do
      assert_raise ArgumentError, ~r/land the run first/, fn ->
        Validation.validate_stop(scope, nil, [{unquote(opt), "anything"}])
      end
    end
  end
end
