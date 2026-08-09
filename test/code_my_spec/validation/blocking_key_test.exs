defmodule CodeMySpec.Validation.BlockingKeyTest do
  @moduledoc """
  The identity R8 counts repeats on.

  A stop blocked on problems used to repeat forever: the escape existed and was
  wired to the call site, but the counter it reads was only ever advanced by
  `TaskEvaluator`, so a problems-only block never armed it. Eight consecutive
  stops were observed on a finding that was real, correctly attributed, and
  belonged to a story that did not exist in this project's copy — nothing the
  working agent could legitimately do.

  Counting on the *rendered reason* would have looked like a fix and not been
  one. That text carries relative ages ("stale, last ran 3 minutes ago"), so its
  hash changes on every stop and the streak never builds — inert in exactly the
  case that needs it, an analyzer lagging while the same findings block.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Validation

  defp finding(opts \\ []) do
    %{
      source: Keyword.get(opts, :source, "credo"),
      file_path: Keyword.get(opts, :file, "test/spex_givens_test.exs"),
      line: Keyword.get(opts, :line, 102),
      message: Keyword.get(opts, :message, "given_ block states a precondition it does not set")
    }
  end

  test "the same findings give the same key" do
    assert Validation.blocking_key([finding()]) == Validation.blocking_key([finding()])
  end

  # The property the whole change rests on. Nothing about waiting may move this,
  # or the streak resets every stop and the loop never breaks.
  test "order does not change it" do
    a = finding(file: "a.ex")
    b = finding(file: "b.ex")

    assert Validation.blocking_key([a, b]) == Validation.blocking_key([b, a])
  end

  test "a fixed finding changes it" do
    two = Validation.blocking_key([finding(file: "a.ex"), finding(file: "b.ex")])
    one = Validation.blocking_key([finding(file: "a.ex")])

    refute two == one,
           "fixing one of two findings must reset the streak — the block is doing its job"
  end

  test "a new finding changes it" do
    before = Validation.blocking_key([finding()])
    after_edit = Validation.blocking_key([finding(), finding(file: "new.ex")])

    refute before == after_edit
  end

  test "a moved line changes it" do
    refute Validation.blocking_key([finding(line: 102)]) ==
             Validation.blocking_key([finding(line: 118)])
  end

  # Nothing blocking, nothing to count. `record_block/3` skips a nil rather than
  # advancing a streak on an empty set.
  test "no findings has no key" do
    assert Validation.blocking_key([]) == nil
  end
end
