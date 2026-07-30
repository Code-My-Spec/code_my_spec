defmodule CodeMySpec.LeasesTest do
  # Not async: advisory locks are per-database, not per-transaction, so two
  # tests taking locks at once are genuinely sharing state even though their
  # rows are sandboxed.
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Leases

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)

    # A session per test, stopped by ExUnit afterwards. Stopping it is what
    # releases the locks — which is the behaviour under test, so exercising it
    # between every test is the point rather than a tidiness measure.
    # Under the default name: that is the one Leases.acquire/2 talks to.
    start_supervised!(Leases.Session)

    %{scope: full_scope_fixture()}
  end

  describe "acquire/2" do
    test "an unclaimed project is claimable", %{scope: scope} do
      assert :ok = Leases.acquire(scope, "the harness at /workspace/app")
    end

    test "the same harness re-acquiring is not refused", %{scope: scope} do
      assert :ok = Leases.acquire(scope, "the harness at /workspace/app")

      assert :ok = Leases.acquire(scope, "the harness at /workspace/app"),
             "advisory locks are re-entrant per session; a re-check must not refuse"
    end

    test "two projects are leased independently", %{scope: scope} do
      other = full_scope_fixture()

      assert :ok = Leases.acquire(scope, "harness a")
      assert :ok = Leases.acquire(other, "harness b")
    end

    test "releasing frees the project", %{scope: scope} do
      :ok = Leases.acquire(scope, "harness a")
      :ok = Leases.release(scope)

      assert :ok = Leases.acquire(scope, "harness b")
    end
  end

  describe "holder/1" do
    test "an unclaimed project has no holder", %{scope: scope} do
      refute Leases.holder(scope)
    end

    test "asking who holds a free project does not claim it", %{scope: scope} do
      refute Leases.holder(scope)

      assert :ok = Leases.acquire(scope, "harness a"),
             "holder/1 must give back any lock it took to answer the question"
    end
  end

  describe "the session process is the lease" do
    test "a second session cannot take a project the first one holds", %{scope: scope} do
      :ok = Leases.acquire(scope, "the harness at /workspace/app")

      # A second harness is a second OS process with its own connection. Another
      # Session process with its own Postgrex connection is the same thing as
      # far as Postgres is concerned.
      second = start_supervised!({Leases.Session, name: :second_harness}, id: :second)

      refute Leases.Session.try_lock(scope.active_project_id, second),
             "a live harness's lease must block another harness"
    end

    test "the lease frees when the holding session dies", %{scope: scope} do
      # GenServer.start, not start_link — killing a linked process would take
      # the test with it, and killing is the case under test.
      {:ok, holder} = GenServer.start(Leases.Session, [])
      assert Leases.Session.try_lock(scope.active_project_id, holder)

      second = start_supervised!({Leases.Session, name: :survivor}, id: :survivor)
      refute Leases.Session.try_lock(scope.active_project_id, second)

      # No release, no expiry — the connection just goes, the way it would if
      # the container were killed.
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 2_000

      assert eventually(fn -> Leases.Session.try_lock(scope.active_project_id, second) end),
             "a dead harness must not keep holding a project"
    end
  end

  describe "describe/1" do
    test "names the working directory so the reader knows which checkout to stop" do
      assert Leases.describe("/workspace/todo_sprite") == "the harness at /workspace/todo_sprite"
    end

    test "falls back when there is no working directory" do
      assert Leases.describe(nil) == "another harness"
    end
  end

  # Postgres releases the lock as it reaps the closed connection, which is
  # prompt but not synchronous with the process dying.
  defp eventually(fun, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
