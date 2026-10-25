defmodule CmsHarness.AShardedRunFinishesWhenItsRunnerExitsTest do
  @moduledoc """
  A spex run split across shards streams as one run and finishes once, when
  its runner exits. Its shards report no finish of their own: the first to end
  would have read as the run's end while the others still ran (issue 96d02161).
  """
  use ExUnit.Case, async: true

  alias CmsHarness.RunLink

  @run_id 7_000_001

  setup do
    root = "/tmp/sharded-run-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    name = :"run_link_#{System.unique_integer([:positive])}"
    link = start_supervised!({RunLink, name: name})
    # What `{:expect, …}` records, without starting distribution in the suite.
    :sys.replace_state(link, &Map.put(&1, @run_id, root))
    %{link: link}
  end

  defp event(link, event), do: send(link, {:run_event, @run_id, event})

  defp delivered do
    receive do
      {:"$gen_cast", {:analysis_event, %{"event" => event}}} -> event
    after
      500 -> :none
    end
  end

  test "shards' events stream until the runner exits, which finishes the run", %{link: link} do
    event(link, %{"event" => "test", "name" => "shard 1's", "state" => "passed"})
    event(link, %{"event" => "test", "name" => "shard 3's", "state" => "passed"})
    assert %{"name" => "shard 1's"} = delivered()
    assert %{"name" => "shard 3's"} = delivered()

    :ok = RunLink.exited(@run_id, link)
    assert %{"event" => "finished"} = delivered()

    event(link, %{"event" => "test", "name" => "late", "state" => "passed"})
    assert delivered() == :none
  end

  test "a run that reported finishing finishes once", %{link: link} do
    event(link, %{"event" => "finished"})
    assert %{"event" => "finished"} = delivered()

    :ok = RunLink.exited(@run_id, link)
    assert delivered() == :none
  end
end
