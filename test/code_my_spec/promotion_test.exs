defmodule CodeMySpec.PromotionTest do
  @moduledoc """
  What a promotion does when it cannot reach the disk.

  Every spec in story 1046 builds `Environment.new(:local, root)` and drives a
  real checkout on the machine running the suite. Production does not look like
  that: a project's checkout is on someone else's machine, `scope.environment`
  is a harness environment, and `Environments.Harness.cmd/4` answers
  `{:error, :not_supported_on_harness}` — it carries file operations to the
  disk, not commands.

  So the one environment that matters was the one nothing covered, and the
  tool's first real invocation crashed with `-32603 Internal error`:
  `refuse_uncommitted/2` matched the error tuple against its `{out, _}` clause
  and called `String.trim(:error)`. The agent was told the tool was broken,
  which is both useless and wrong.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion

  describe "an environment that cannot run commands" do
    test "is refused by name rather than crashing" do
      scope = %{full_scope_fixture() | environment: Environment.new(:harness, nil)}

      assert {:error, %{environment: :harness, reason: reason}} = Promotion.promote(scope)

      assert reason =~ "harness",
             "the refusal has to name why it cannot promote, or the agent reads it " <>
               "as the tool being broken. Got: #{reason}"

      assert reason =~ "just restart" or reason =~ "git",
             "an agent refused here needs to know what it can do instead. Got: #{reason}"
    end

    test "a scope with no environment at all is refused too" do
      scope = %{full_scope_fixture() | environment: nil}

      assert {:error, %{reason: reason}} = Promotion.promote(scope)
      assert reason =~ "no environment"
    end

    # The specific crash. `String.trim(:error)` is what a caller gets for
    # assuming `Environments.cmd/4` always answers `{binary, status}`, and the
    # guard above is only one of several call sites that assumed it.
    test "no promotion path raises a FunctionClauseError on an error tuple" do
      scope = %{full_scope_fixture() | environment: Environment.new(:harness, nil)}

      # Would raise before the fix rather than returning a tuple.
      assert {:error, %{}} = Promotion.promote(scope)
    end
  end
end
