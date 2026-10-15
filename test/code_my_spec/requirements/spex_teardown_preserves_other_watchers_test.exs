defmodule CodeMySpec.Requirements.SpexTeardownPreservesOtherWatchersTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.UsersFixtures
  alias CodeMySpecSpex.Fixtures

  test "ending one spex stops its projects without stopping another spex's watcher" do
    first = start_scenario()
    second = start_scenario()

    on_exit(first.test_pid, fn -> ExUnit.OnExitHandler.run(first.test_pid, 30_000) end)
    on_exit(second.test_pid, fn -> ExUnit.OnExitHandler.run(second.test_pid, 30_000) end)

    assert Process.alive?(first.primary)
    assert Process.alive?(first.secondary)
    assert Process.alive?(second.primary)
    assert Process.alive?(second.secondary)

    assert :ok = ExUnit.OnExitHandler.run(first.test_pid, 30_000)
    on_exit(first.test_pid, fn -> :ok end)

    refute Process.alive?(first.primary)
    refute Process.alive?(first.secondary)
    assert Process.alive?(second.primary)
    assert Process.alive?(second.secondary)
    assert is_map(GenServer.call(second.primary, :status))

    assert :ok = ExUnit.OnExitHandler.run(second.test_pid, 30_000)
    on_exit(second.test_pid, fn -> :ok end)
    refute Process.alive?(second.primary)
    refute Process.alive?(second.secondary)
  end

  # Run the actual Case setup and registered callbacks with separate sandbox
  # owners. ExUnit's callback registry lets teardown be driven deterministically
  # while the other scenario remains alive, without depending on test order.
  defp start_scenario do
    task =
      Task.async(fn ->
        ExUnit.OnExitHandler.register(self())
        CodeMySpecSpex.Case.__ex_unit__(:setup, %{async: true})
        primary_scope = UsersFixtures.full_scope_fixture()
        secondary_scope = UsersFixtures.full_scope_fixture()
        Fixtures.watch_graph(primary_scope)
        Fixtures.watch_graph(secondary_scope)
        Fixtures.watch_graph(primary_scope)
        {:ok, primary} = GraphWatcher.ensure_watching(primary_scope)
        {:ok, secondary} = GraphWatcher.ensure_watching(secondary_scope)
        %{test_pid: self(), primary: primary, secondary: secondary}
      end)

    Task.await(task, 60_000)
  end
end
