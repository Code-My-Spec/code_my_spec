defmodule CodeMySpec.PromotionTest do
  @moduledoc """
  Where a promotion's disk work runs, and what it does when it cannot run.

  Every spec in story 1046 builds `Environment.new(:local, root)` and drives a
  real checkout on the machine running the suite. Production does not look like
  that: a project's checkout is on someone else's machine, `scope.environment`
  is a harness environment, and `Environments.Harness.cmd/4` answers
  `{:error, :not_supported_on_harness}` — it carries file operations to the
  disk, not commands.

  So the one environment that matters was the one nothing covered, and the
  tool's first real invocation crashed with `-32603 Internal error`:
  `String.trim(:error)`, from a caller assuming `cmd/4` always answers
  `{binary, status}`.

  `Promotion.Runner` is the answer — the gate stays on the server where the
  database is, and the three disk operations run wherever the checkout is.
  These cover the paths that have no disk to reach.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.{Runner, Steps}

  describe "a runner with nowhere to run" do
    test "a harness environment with no working copy id says so" do
      scope = %{full_scope_fixture() | environment: Environment.new(:harness, nil)}

      assert {:error, %{reason: reason}} = Runner.precheck(scope, "/somewhere", nil)

      assert reason =~ "working copy id",
             "the harness is addressed by id, not by path — a missing id has to " <>
               "name itself rather than surface as a failed lookup. Got: #{reason}"
    end

    test "a harness that is not connected is reported, not crashed into" do
      scope = %{full_scope_fixture() | environment: Environment.new(:harness, nil)}

      assert {:error, %{reason: reason}} =
               Runner.restart(scope, "/somewhere", Ecto.UUID.generate())

      assert reason =~ "could not reach",
             "an unreachable machine is a state to report, not an exception. " <>
               "Got: #{reason}"
    end

    test "a scope with no environment at all is refused" do
      scope = %{full_scope_fixture() | environment: nil}

      assert {:error, %{reason: reason}} = Runner.merge(scope, "/somewhere", "main", nil)
      assert reason =~ "no environment"
    end
  end

  describe "a command that errors instead of running" do
    # The exact crash. `Environments.cmd(nil, ...)` answers `{"no environment", 1}`
    # and a harness environment answers `{:error, :not_supported_on_harness}`;
    # `Steps` has to survive both without trimming an atom.
    test "does not raise out of a step" do
      assert {:error, %{reason: reason}} = Steps.precheck(nil, "/nowhere")
      assert is_binary(reason)
    end

    test "a step handed a harness environment reports rather than raises" do
      env = Environment.new(:harness, nil)

      assert {:error, %{reason: reason}} = Steps.precheck(env, "/nowhere")

      assert is_binary(reason),
             "this is the call that produced `String.trim(:error)` and a -32603 " <>
               "on the tool's first real use"
    end
  end
end
