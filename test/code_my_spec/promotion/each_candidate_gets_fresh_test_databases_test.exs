defmodule CodeMySpec.Promotion.EachCandidateGetsFreshTestDatabasesTest do
  @moduledoc """
  The gate drops its test databases before each candidate, so an ejected
  candidate's migrations cannot fail the next one (2026-10-11: a candidate
  dropping `qa_story_reviews` was ejected, and the next failed 749 tests on a
  schema it never had). Nothing but a test database is ever dropped.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Support.InMemoryEnvironment
  alias Mix.Tasks.Cms.DropTestDatabase

  @gate "/w/gate"

  defp a_gate(answer) do
    test = self()

    {:ok, env} =
      InMemoryEnvironment.create(
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
      assert_received {:mix, @gate, ["cms.drop_test_database"], env}
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

  describe "the drop task" do
    test "drops a partition's test database under MIX_ENV=test" do
      assert DropTestDatabase.droppable([database: "code_my_spec_testh1a2b3c4a"], :test) == :ok
    end

    # `CMS_DRILL_DB` points the test config at the shared development database.
    test "refuses the development database even under MIX_ENV=test" do
      assert {:error, reason} = DropTestDatabase.droppable([database: "code_my_spec_dev"], :test)
      assert reason =~ "not named as a test database"
    end

    # A child with MIX_ENV scrubbed once acted on dev (2026-08-13).
    test "drops nothing outside MIX_ENV=test" do
      assert {:error, reason} = DropTestDatabase.droppable([database: "code_my_spec_test"], :dev)
      assert reason =~ "MIX_ENV=dev"
    end

    test "refuses a database the repo cannot name" do
      assert {:error, _} = DropTestDatabase.droppable([], :test)
    end
  end
end
