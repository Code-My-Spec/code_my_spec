defmodule CmsHarness.StaleDepsHealTest do
  @moduledoc """
  fc08e5e2. A promote that moves `mix.lock` leaves every other checkout's
  `deps/` behind, and every analyzer there refuses until somebody fetches. The
  harness fetches once and runs again, and a fetch that fails says so plainly.
  The policy only — `run` and `fetch` stand in for `mix`.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Analysis

  @refusal "Unchecked dependencies for environment dev:\\n* alloy lock mismatch\\n" <>
             "** (Mix) Can't continue due to errors on dependencies"

  defp counting(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn ->
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end
  end

  defp never_fetch, do: fn -> flunk("fetched deps for a run that did not need it") end

  test "a run that is not refused is returned as it is, with no fetch" do
    run = counting([{:ok, %{"diagnostics" => []}}])
    assert {:ok, %{"diagnostics" => []}} = Analysis.heal_stale_deps(run, never_fetch())
  end

  test "a refused run fetches once and runs again" do
    run = counting([{:error, @refusal}, {:ok, %{"diagnostics" => []}}])
    test = self()

    fetch = fn ->
      send(test, :fetched)
      :ok
    end

    assert {:ok, %{"diagnostics" => []}} = Analysis.heal_stale_deps(run, fetch)
    assert_received :fetched
  end

  test "the compiler's own problem for it heals the same way" do
    problem = %{
      "message" => "This checkout cannot satisfy its own mix.lock, so no analyzer can run here.",
      "severity" => "error"
    }

    run = counting([{:ok, %{"diagnostics" => [problem]}}, {:ok, %{"diagnostics" => []}}])
    assert {:ok, %{"diagnostics" => []}} = Analysis.heal_stale_deps(run, fn -> :ok end)
  end

  test "a fetch that fails is reported as one clear reason" do
    run = counting([{:error, @refusal}])

    assert {:error, reason} =
             Analysis.heal_stale_deps(run, fn -> {:error, "** (Mix.Error) hex is offline"} end)

    assert reason =~ "deps out of date with mix.lock"
    assert reason =~ "`mix deps.get` in this working copy failed"
    assert reason =~ "hex is offline"
  end

  describe "the fetch lock" do
    test "takes the lock and answers what the fetch answered" do
      assert :ok =
               Analysis.serialize_deps_get("/tmp/heal-#{System.unique_integer()}", fn -> :ok end)
    end

    test "two fetches for one checkout never overlap" do
      cwd = "/tmp/heal-#{System.unique_integer()}"
      test = self()

      fetch = fn tag ->
        fn ->
          send(test, {:in, tag})

          receive do
            {:release, ^tag} -> :ok
          end

          send(test, {:out, tag})
          :ok
        end
      end

      first = Task.async(fn -> Analysis.serialize_deps_get(cwd, fetch.(:a)) end)
      assert_receive {:in, :a}
      second = Task.async(fn -> Analysis.serialize_deps_get(cwd, fetch.(:b)) end)
      refute_receive {:in, :b}, 200

      send(first.pid, {:release, :a})
      assert_receive {:out, :a}
      assert_receive {:in, :b}, 5_000
      send(second.pid, {:release, :b})
      assert :ok = Task.await(first)
      assert :ok = Task.await(second)
    end
  end
end
