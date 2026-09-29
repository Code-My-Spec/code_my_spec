defmodule CmsHarness.AnalysisCapTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Analysis

  # e82d6a37: a byte cut through a `│` in a framed warning left invalid UTF-8
  # and the channel serializer crashed on it.
  test "a cut through a multi-byte character still yields valid UTF-8" do
    # 99_999 ASCII bytes put the cap one byte into the 3-byte `│`.
    output = String.duplicate("a", 99_999) <> String.duplicate("│", 10)

    capped = Analysis.cap(output)

    assert String.valid?(capped)
    assert String.ends_with?(capped, "\n… (truncated)")
    assert Jason.encode!(%{"output" => capped})
  end

  test "invalid UTF-8 in the input is scrubbed" do
    capped = Analysis.cap(<<"warning ", 0xE2, 0x94, " done">>)

    assert String.valid?(capped)
    assert capped =~ "warning"
    assert capped =~ "done"
  end

  test "output under the cap is untouched" do
    assert Analysis.cap("1377 │ @doc") == "1377 │ @doc"
  end
end
