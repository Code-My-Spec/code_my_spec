defmodule CodeMySpec.Promotion.EachCandidateGetsFreshTestDatabasesTest do
  @moduledoc """
  The gate drops its test databases before each candidate, so an ejected
  candidate's migrations cannot fail the next one (2026-10-11: a candidate
  dropping `qa_story_reviews` was ejected, and the next failed 749 tests on a
  schema it never had). Nothing but a test database is ever dropped.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Support.InMemoryExecutionContext

  @gate "/w/gate"

  defp a_gate(answer) do
    test = self()

    {:ok, env} =
      InMemoryExecutionContext.create(
        shell: fn "mix", args, opts ->
          send(test, {:mix, Keyword.fetch!(opts, :cd), args, Keyword.get(opts, :env, [])})
          answer.(opts)
        end
      )

    env
  end

  test "each of the gate's databases is dropped in the test environment" do
    env = a_gate(fn _opts -> {"dropped\n", 0} end)

    assert {:ok, %{dropped: ["ha", "has", "haa"]}} =
             Steps.reset_test_databases(env, @gate, ["ha", "has", "haa"])

    for partition <- ["ha", "has", "haa"] do
      assert_received {:mix, @gate, ["run", "--no-start", "-e", _script], env}
      assert {"MIX_ENV", "test"} in env
      assert {"MIX_TEST_PARTITION", partition} in env
    end
  end

  test "a database that cannot be dropped stops the reset, naming it" do
    env = a_gate(fn _opts -> {"could not drop: in use\n", 1} end)

    assert {:error, %{reason: reason}} = Steps.reset_test_databases(env, @gate, ["ha", "has"])
    assert reason =~ "ha"
    assert reason =~ "could not drop: in use"
    assert_received {:mix, @gate, _, _}
    refute_received {:mix, @gate, _, _}, "the next database was dropped after one failed"
  end

  # It runs in the project's own VM, so any project's gate can run it: a task
  # of ours once failed every other project's gate (2026-10-12).
  test "the drop needs nothing the project does not already have" do
    env = a_gate(fn _opts -> {"dropped\n", 0} end)
    {:ok, _} = Steps.reset_test_databases(env, @gate, ["ha"])
    assert_received {:mix, @gate, ["run", "--no-start", "-e", script], _env}
    refute script =~ "cms."
    assert script =~ ":ecto_repos"
  end

  describe "what the drop refuses" do
    setup do
      {refusal, _} = Code.eval_string(Steps.refusal_source())
      %{refusal: refusal}
    end

    test "a partition's test database under MIX_ENV=test is dropped", %{refusal: refusal} do
      assert refusal.(:test, "code_my_spec_testh1a2b3c4a") == nil
    end

    # `CMS_DRILL_DB` points the test config at the shared development database.
    test "the development database is refused even under MIX_ENV=test", %{refusal: refusal} do
      assert refusal.(:test, "code_my_spec_dev") =~ "not named as a test database"
    end

    # A child with MIX_ENV scrubbed once acted on dev (2026-08-13).
    test "nothing is dropped outside MIX_ENV=test", %{refusal: refusal} do
      assert refusal.(:dev, "code_my_spec_test") =~ "MIX_ENV=dev"
    end

    test "a database the repo cannot name is refused", %{refusal: refusal} do
      assert refusal.(:test, nil) =~ "not named as a test database"
    end
  end
end
