defmodule CodeMySpec.Sessions.SubagentHeartbeatTest do
  @moduledoc """
  A sub-agent making tool calls is alive, and until now nothing recorded that.

  `last_heartbeat_at` was set once at `SubagentStart` and never again, so
  `Session.active_subagents/2` dropped any sub-agent still working after
  `subagent_ttl_minutes` — ten by default.

  That was survivable while the stop hook's exemption keyed on the task row,
  which never expires. It stopped being survivable when the exemption started
  asking the registration instead: a sub-agent running longer than ten minutes
  falls off the roster mid-flight, and the parent begins blocking on problems
  while its sub-agent is demonstrably working — the exact thing the exemption
  exists to prevent. Sub-agents here routinely run far longer; one sat in a
  single browser call for 1800s the day this was written.

  The rule these pin is narrow and both halves matter: refresh a registration
  that exists, and never create one that does not. A tool call carrying an
  `agent_id` this session has no registration for is not evidence a sub-agent
  started — it is evidence something else is using that id — and registering
  from it would make the roster unfalsifiable.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.Subagent

  defp session(subagents), do: %Session{subagents: subagents}

  defp registered(agent_id, minutes_ago) do
    %Subagent{
      id: Ecto.UUID.generate(),
      agent_id: agent_id,
      agent_name: agent_id,
      last_heartbeat_at: DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
    }
  end

  defp subagents_after_touch(session, agent_id) do
    session
    |> Session.touch_subagent(agent_id)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:subagents)
  end

  describe "touch_subagent/2" do
    test "a registered sub-agent's evidence of life is refreshed" do
      s = session([registered("qa-873b", 30)])

      [touched] = subagents_after_touch(s, "qa-873b")

      assert DateTime.diff(DateTime.utc_now(), touched.last_heartbeat_at) < 5,
             "a tool call from this agent just happened, so its heartbeat is now"
    end

    # The whole point: a 30-minute-old registration is outside the default
    # 10-minute TTL and would have been dropped from the roster mid-work.
    test "refreshing brings a sub-agent back inside the TTL" do
      s = session([registered("qa-873b", 30)])

      assert Session.active_subagents(s, 10) == [],
             "precondition — without a refresh this agent has already fallen off"

      refreshed = session(subagents_after_touch(s, "qa-873b"))

      assert [%{agent_id: "qa-873b"}] = Session.active_subagents(refreshed, 10)
    end

    test "an unregistered agent_id does not become registered" do
      s = session([registered("qa-873b", 1)])

      ids = s |> subagents_after_touch("some-other-agent") |> Enum.map(& &1.agent_id)

      assert ids == ["qa-873b"],
             "a tool call is not a registration. Creating one here would mean the " <>
               "roster could never say no, and the stop hook's exemption reads it."
    end

    test "touching one sub-agent leaves the others alone" do
      s = session([registered("a", 20), registered("b", 20)])

      touched = subagents_after_touch(s, "a")
      by_id = Map.new(touched, &{&1.agent_id, &1})

      assert DateTime.diff(DateTime.utc_now(), by_id["a"].last_heartbeat_at) < 5
      assert DateTime.diff(DateTime.utc_now(), by_id["b"].last_heartbeat_at) > 60
    end

    test "a session with no sub-agents is untouched" do
      assert subagents_after_touch(session([]), "qa-873b") == []
    end
  end
end
