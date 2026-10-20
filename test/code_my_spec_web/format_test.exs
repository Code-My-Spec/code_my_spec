defmodule CodeMySpecWeb.FormatTest do
  use ExUnit.Case, async: true

  alias CodeMySpecWeb.Format

  test "counts read in a few characters" do
    assert Enum.map(
             [0, 999, 1_000, 1_234, 1_999, 12_345, 123_456, 1_234_567, 45_600_000, 2_000_000_000],
             &Format.compact/1
           ) == ["0", "999", "1k", "1.23k", "1.99k", "12.3k", "123k", "1.23m", "45.6m", "2b"]
  end
end
