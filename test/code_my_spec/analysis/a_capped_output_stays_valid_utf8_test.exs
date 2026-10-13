defmodule CodeMySpec.Analysis.ACappedOutputStaysValidUtf8Test do
  @moduledoc """
  An analyzer's output, cut to its cap, stays valid UTF-8.

  The server cut on a byte, so a cut after the first byte of a "—" left 0xe2
  before the truncation marker. Postgres refused the row ("invalid byte
  sequence for encoding UTF8: 0xe2 0x0a 0xe2"), and a green exunit run was
  recorded as one that could not run, ejecting the batch (2026-10-12).
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners

  defp exunit(output) do
    {:ok, result} =
      Runners.from_raw("exunit", %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" => output,
        "stats" => %{"tests" => 1, "failures" => 0},
        "diagnostics" => []
      })

    result.output
  end

  test "a cut that lands inside a character drops the partial character" do
    # 99,999 ASCII bytes, then "—" (three bytes): a 100,000-byte cut keeps only
    # its first byte.
    output = exunit(String.duplicate("a", 99_999) <> "— and more")

    assert String.valid?(output)
    assert String.ends_with?(output, "\n… (truncated)")
  end

  test "output under the cap is kept as it is" do
    assert exunit("5 tests, 0 failures — done") == "5 tests, 0 failures — done"
  end
end
