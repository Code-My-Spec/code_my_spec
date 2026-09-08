defmodule CodeMySpec.Compile.UnsatisfiedDepsAreTheAgentsProblemTest do
  @moduledoc """
  A checkout that cannot satisfy its own `mix.lock` is told to fix it.

  `mix.lock` is committed and `deps/` is not, so a dependency added in one
  worktree reaches every other with the next pull and has to be fetched once.
  Until it is, `mix compile` exits 1 with "Unchecked dependencies" and writes no
  diagnostics file — the same shape as a config change or lock contention, so it
  was classified as transient.

  It is not transient. Nothing heals it but `mix deps.get`.

  Measured on 2026-09-08: `ex_slop` and an alloy fork landed on main and seven
  checkouts on one machine began failing every analyzer in about a second. The
  run stayed open on the server, the output was discarded, and every stop
  reported "analysis pending" rather than naming the cause — for hours, with the
  one line that explains it sitting in a `Logger.warning` nobody reads.

  Reported as a problem rather than swallowed, because the agent is standing in
  that checkout and can fix it. John: "shouldn't we send a message to the model
  in that case and tell it that it needs to fix that thing? Isn't that a
  deliverable message?" The stop menu ranks problems above everything else, so
  it reaches the agent before it is asked to do anything else.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Compile

  @unchecked """
  ==> code_my_spec
  Unchecked dependencies for environment dev:
  * ex_slop (Hex package)
    the dependency is not available, run "mix deps.get"
  * req (Hex package)
    lock mismatch: the dependency is out of date. To fetch locked version run "mix deps.get"
  ** (Mix) Can't continue due to errors on dependencies
  """

  test "it is reported, not swallowed" do
    assert [problem] = Compile.extract_compiler_errors(@unchecked)
    assert problem["severity"] == "error"
  end

  test "and the report says what to run" do
    [problem] = Compile.extract_compiler_errors(@unchecked)

    assert problem["message"] =~ "mix deps.get",
           "an agent told its analyzers are broken and not told the one command is stuck"
  end

  # Which dependencies is the actionable half. "req is out of date" says a pull
  # moved the lock; the banner alone reads as a broken machine.
  test "and which dependencies are unhappy" do
    [problem] = Compile.extract_compiler_errors(@unchecked)

    assert problem["message"] =~ "ex_slop"
  end

  # It has to beat the transient markers rather than sit behind them: this
  # output carries `Can't continue due to errors on dependencies`, and a checkout
  # mid-failure often prints a transient-looking banner alongside.
  test "it wins over a transient marker in the same output" do
    output = @unchecked <> "\n** (RuntimeError) You must restart your server after changing configuration files\n"

    assert [problem] = Compile.extract_compiler_errors(output)
    assert problem["message"] =~ "mix deps.get"
  end

  describe "what must stay transient" do
    # Both of these genuinely heal themselves. Reporting either would block a
    # stop on a machine that is about to be fine, which is the failure the
    # transient classification exists to prevent.
    test "a config change asking for a restart" do
      output = "==> code_my_spec\n** (RuntimeError) You must restart your server after changing configuration files\n"

      assert Compile.extract_compiler_errors(output) == []
    end

    test "mix progress banners with no diagnostics" do
      output = "==> boundary\n==> phoenix\nCompiling 12 files (.ex)\n"

      assert Compile.extract_compiler_errors(output) == []
    end
  end

  # The path that was already working keeps working: a genuine compiler error
  # recovered from raw output is still one error per line, not a dependency
  # complaint.
  test "a real compile error is still a real compile error" do
    output = "** (CompileError) lib/foo.ex:3: undefined function bar/0\n"

    assert [problem] = Compile.extract_compiler_errors(output)
    refute problem["message"] =~ "mix deps.get"
  end
end
