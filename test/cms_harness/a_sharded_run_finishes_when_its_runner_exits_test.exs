defmodule CmsHarness.AShardedRunFinishesWhenItsRunnerExitsTest do
  @moduledoc """
  A spex run split across shards streams as one run and finishes once, when
  every shard's exit is in. Its shards report no finish of their own: the
  first to end would have read as the run's end while the others still ran
  (issue 96d02161). A run that crashed before reporting its exit finishes
  when its command exits.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.RunLink

  @run_id 7_000_001

  setup do
    root = "/tmp/sharded-run-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    link = start_supervised!({RunLink, name: :"run_link_#{System.unique_integer([:positive])}"})
    # What `{:expect, …}` records, without starting distribution in the suite.
    run = %{root: root, owner: nil, sessions: %{}, exits: %{}, shards: 1, finished: false}
    :sys.replace_state(link, &Map.put(&1, @run_id, run))
    %{link: link}
  end

  defp event(link, session, seq, event),
    do: send(link, {:run_event, @run_id, session, seq, event})

  defp shard_session, do: spawn_link(fn -> Process.sleep(:infinity) end)

  defp delivered do
    receive do
      {:"$gen_cast", {:analysis_event, %{"event" => event}}} -> event
    after
      300 -> :none
    end
  end

  test "shards' events stream until the last shard's exit, which finishes the run", %{
    link: link
  } do
    {one, three} = {shard_session(), shard_session()}

    event(link, one, 1, %{"event" => "test", "name" => "shard 1's", "state" => "passed"})
    event(link, three, 1, %{"event" => "test", "name" => "shard 3's", "state" => "passed"})
    assert %{"name" => "shard 1's"} = delivered()
    assert %{"name" => "shard 3's"} = delivered()

    event(link, one, 2, %{"event" => "exit", "status" => 0, "shard" => 1, "shards" => 2})
    assert delivered() == :none, "the first shard to end is not the run's end"

    event(link, three, 2, %{"event" => "exit", "status" => 1, "shard" => 2, "shards" => 2})
    assert %{"event" => "finished"} = delivered()

    event(link, one, 3, %{"event" => "test", "name" => "late", "state" => "passed"})
    assert delivered() == :none
  end

  test "a run that never reported its exit finishes once its command exits", %{link: link} do
    :ok = RunLink.exited(@run_id, link)
    assert %{"event" => "finished"} = delivered()

    :ok = RunLink.exited(@run_id, link)
    assert delivered() == :none
  end
end
