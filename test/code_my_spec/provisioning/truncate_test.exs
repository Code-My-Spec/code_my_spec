defmodule CodeMySpec.Provisioning.TruncateTest do
  @moduledoc """
  Both ends survive, because different tools put their one useful line in
  different places — confirmed live against MarketMySpec in both directions:
  apt/gem chatter buries its real cause at the end, a Ruby `gem` crash puts
  its own error line before the backtrace it raises. A single-ended slice
  guesses which convention applies; this does not have to.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Truncate

  test "text within budget is returned unchanged" do
    assert Truncate.head_and_tail("short reason", 300) == "short reason"
  end

  test "keeps a reason at the start and a conclusion at the end, not just one" do
    text = "ERROR: something real" <> String.duplicate("x", 400) <> "the actual conclusion"

    result = Truncate.head_and_tail(text, 100)

    assert result =~ "ERROR: something real"
    assert result =~ "the actual conclusion"
  end

  test "the marker separates the two kept halves" do
    text = String.duplicate("a", 50) <> String.duplicate("b", 400) <> String.duplicate("c", 50)

    result = Truncate.head_and_tail(text, 100)

    assert result =~ "\n…\n"
  end

  test "defaults to a wide enough budget that a real backtrace fits whole" do
    # Roughly the length of the multi-frame Ruby backtrace that first showed
    # both ends of a 300-character budget still missing the line in between.
    text = String.duplicate("\tfrom /usr/lib/ruby/vendor_ruby/rubygems/x.rb:1:in `y'\n", 15)

    assert Truncate.head_and_tail(text) == text
  end

  test "still truncates something genuinely larger than the default budget" do
    text = String.duplicate("x", 5000)

    assert String.length(Truncate.head_and_tail(text)) < String.length(text)
  end
end
