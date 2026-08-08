defmodule CmsHarness.HookDecisionTest do
  @moduledoc """
  The invariant this whole application is shaped around: **"I asked and there is
  nothing to do" and "I could not ask" must never render the same.**

  These are string assertions on purpose. The wording is the interface — a hook
  response is read by an agent and, when something is wrong, by a person at
  three in the morning who needs to know which process is broken.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.HookDecision

  @dir "/work/app"

  describe "the stop hook refuses" do
    test "a disconnected stop blocks rather than allowing" do
      decision = HookDecision.unreachable("stop", :not_connected, @dir)

      assert decision["decision"] == "block",
             "allowing a stop the harness could not verify is the silent green light " <>
               "this design exists to prevent"
    end

    test "a disconnected subagent-stop blocks too" do
      assert %{"decision" => "block"} =
               HookDecision.unreachable("subagent-stop", :not_connected, @dir)
    end

    test "the refusal says the harness never got to ask, not that there is nothing to do" do
      %{"reason" => reason} = HookDecision.unreachable("stop", :not_connected, @dir)

      assert reason =~ "never got to ask"
      refute reason =~ "no work"
    end
  end

  describe "the message names the harness" do
    for reason <- [:not_connected, :no_project, :no_credential, :no_reply, :invalid_config] do
      test "#{reason} points at the harness rather than at the server" do
        text =
          "stop"
          |> HookDecision.unreachable(unquote(reason), @dir)
          |> Map.get("reason")

        assert text =~ "harness",
               "an hour went into a failure that read 'MCP server is down' while the " <>
                 "server was healthy; every one of these has to name the harness"
      end
    end

    # This used to assert the words "the server itself may well be healthy".
    # That was a guess printed as reassurance, and the day it mattered it was
    # wrong — the server was returning 500. Where the harness knows, it now says
    # which end is broken; see "a channel that is down says which end is
    # broken". Where it does not know, it points at the log and claims nothing.
    test "a dropped channel blames neither end when it has not asked" do
      %{"reason" => reason} = HookDecision.unreachable("stop", :not_connected, @dir)

      assert reason =~ "channel to the CodeMySpec server is down"
      assert reason =~ "harness log"
      refute reason =~ "may well be healthy"
    end

    test "a missing project id names the file it should have been in" do
      %{"reason" => reason} = HookDecision.unreachable("stop", :no_project, @dir)

      assert reason =~ ".code_my_spec/config.yml"
      assert reason =~ "CMS_PROJECT_ID"
    end

    test "a missing credential says so instead of looking like an outage" do
      %{"reason" => reason} = HookDecision.unreachable("stop", :no_credential, @dir)

      assert reason =~ "CMS_TOKEN"
      assert reason =~ "never connected"
    end

    # The one case where the connection is fine and the *server* is the
    # suspect. Reading this as a harness problem would send someone to restart
    # the wrong thing.
    test "no reply on a joined channel points away from the harness's connection" do
      %{"reason" => reason} = HookDecision.unreachable("stop", :no_reply, @dir)

      assert reason =~ "channel is joined"
      assert reason =~ "server or the network"
    end
  end

  describe "hooks that decide nothing" do
    test "a session-start does not block the agent, it just says what happened" do
      decision = HookDecision.unreachable("session-start", :not_connected, @dir)

      refute Map.has_key?(decision, "decision")
      assert decision["systemMessage"] =~ "not connected"
    end

    test "pre-tool-use does not block — a disconnected harness must not freeze the agent" do
      decision = HookDecision.unreachable("pre-tool-use", :not_connected, @dir)

      refute Map.has_key?(decision, "decision")
    end
  end

  describe "a channel that is down says which end is broken" do
    # The refusal used to say "the server itself may well be healthy". The day
    # it mattered the server was returning 500, and that hedge sent me to read
    # the harness's socket code instead of restarting the server.
    test "a 5xx names the server, not the harness" do
      reason = HookDecision.unreachable("stop", {:not_connected, {:http, 500}}, @dir)["reason"]

      assert reason =~ "500"
      assert reason =~ "the server, not the harness"
      refute reason =~ "may well be healthy"
    end

    test "a server that answers points at the harness instead" do
      reason = HookDecision.unreachable("stop", {:not_connected, {:http, 200}}, @dir)["reason"]

      assert reason =~ "the server is up",
             "if the server answers and the channel is still down, the socket " <>
               "or the credential is the fault and that is where to look"

      refute reason =~ "the server, not the harness"
    end

    test "a server that is not there at all says so" do
      reason =
        HookDecision.unreachable("stop", {:not_connected, {:error, :econnrefused}}, @dir)[
          "reason"
        ]

      assert reason =~ "econnrefused"
      assert reason =~ "not answering at all"
    end

    test "all three still block — none of them is permission to stop" do
      for probe <- [{:http, 500}, {:http, 200}, {:error, :econnrefused}] do
        assert %{"decision" => "block"} =
                 HookDecision.unreachable("stop", {:not_connected, probe}, @dir)
      end
    end
  end

  describe "the second pass" do
    # Blocking forever is its own outage: the agent can neither stop nor do
    # anything useful, and an unattended run burns its whole budget on it.
    test "a stop that has already been blocked is allowed — loudly" do
      decision =
        HookDecision.unreachable("stop", :not_connected, @dir, %{"stop_hook_active" => true})

      refute Map.has_key?(decision, "decision")
      assert decision["systemMessage"] =~ "unverified"
    end

    test "and it names everything that was not checked, so it cannot read as clean" do
      %{"systemMessage" => message} =
        HookDecision.unreachable("stop", :not_connected, @dir, %{"stop_hook_active" => true})

      assert message =~ "not the compiler"
      assert message =~ "not the tests"
      assert message =~ "not the requirement graph"
    end

    test "an allowed-because-unreachable stop still looks nothing like a clean stop" do
      unreachable =
        HookDecision.unreachable("stop", :not_connected, @dir, %{"stop_hook_active" => true})

      # What a server that actually answered "nothing to do" returns.
      clean = %{}

      refute unreachable == clean
      assert map_size(unreachable) > 0
    end
  end

  describe "a server that answered is not a server that was silent" do
    # An hour went into reading "no answer back in time" while the server was
    # replying in two milliseconds and naming the problem. A refusal and a
    # silence need different fixes, so they must not read alike.
    test "a refusal quotes the server instead of blaming the network" do
      refused =
        HookDecision.unreachable("stop", {:refused, %{"reason" => "unknown_event"}}, @dir)

      reason = refused["reason"]

      assert reason =~ "unknown_event", "the server's own words are what identify the fault"
      refute reason =~ "no answer back in time"
      refute reason =~ "or the network"
    end

    test "it still blocks — an unreadable answer is not permission to stop" do
      assert %{"decision" => "block"} =
               HookDecision.unreachable("stop", {:refused, :anything}, @dir)
    end

    test "a timeout and a refusal do not render the same" do
      timed_out = HookDecision.unreachable("stop", :no_reply, @dir)["reason"]
      refused = HookDecision.unreachable("stop", {:refused, :boom}, @dir)["reason"]

      refute timed_out == refused
    end

    test "a non-deciding hook says it too, as an advisory" do
      assert %{"systemMessage" => message} =
               HookDecision.unreachable("session-start", {:refused, :boom}, @dir)

      assert message =~ "boom"
    end
  end
end
