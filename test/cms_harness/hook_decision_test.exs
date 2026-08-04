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

    test "a dropped channel says the server may well be fine" do
      %{"reason" => reason} = HookDecision.unreachable("stop", :not_connected, @dir)
      assert reason =~ "server itself may well be healthy"
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
end
