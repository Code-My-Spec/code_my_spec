defmodule CodeMySpec.Utils.Utf8Test do
  use ExUnit.Case, async: true

  alias CodeMySpec.Utils.Utf8

  describe "valid_prefix/2" do
    test "returns the binary unchanged when it fits the budget" do
      assert Utf8.valid_prefix("hello", 5) == "hello"
      assert Utf8.valid_prefix("hello", 99) == "hello"
    end

    test "truncates ASCII at the exact byte budget" do
      assert Utf8.valid_prefix("abc_def_ghi", 7) == "abc_def"
    end

    test "never splits a multi-byte character — the em-dash case" do
      # "step three — ..." — the em-dash (E2 80 94) starts at byte 11.
      s = "step three — does the thing"

      for budget <- 0..30 do
        prefix = Utf8.valid_prefix(s, budget)
        assert String.valid?(prefix), "budget=#{budget} produced invalid UTF-8"
        assert byte_size(prefix) <= budget
      end
    end

    test "backs off partial trailing bytes rather than emitting them" do
      s = "ab—"
      # byte budget lands one byte into the 3-byte em-dash -> drop the partial char
      assert Utf8.valid_prefix(s, 3) == "ab"
      # full em-dash fits
      assert Utf8.valid_prefix(s, 5) == "ab—"
    end

    test "the truncated result is always JSON-encodable" do
      s = "rule — when the agent — does — the thing — repeatedly"

      for budget <- 0..byte_size(s) do
        prefix = Utf8.valid_prefix(s, budget)
        assert {:ok, _} = Jason.encode(prefix)
      end
    end

    test "handles empty input and zero budget" do
      assert Utf8.valid_prefix("", 5) == ""
      assert Utf8.valid_prefix("anything", 0) == ""
    end
  end
end
