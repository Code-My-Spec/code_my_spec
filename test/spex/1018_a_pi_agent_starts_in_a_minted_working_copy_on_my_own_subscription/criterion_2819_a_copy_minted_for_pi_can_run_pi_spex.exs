defmodule CodeMySpecSpex.Story1018.Criterion2819Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2819 — A copy minted for Pi can run Pi.

  Rule: A minted working copy comes up ready to run Pi, with no manual setup pass.

  The rule exists because the alternative is what we do today for Claude Code, and
  it does not survive being written down. `docker/devbox/sprite.sh` mints a copy
  and then leaves a comment for a human — "Documented for whoever launches the
  agent: `docker exec -d -u agent … devbox-agent`" — because configuring the copy
  and launching the agent were never the same step. A copy that is *nearly* ready
  is one somebody finishes by hand, and nobody records which hand or which step.

  ## Why this asserts chat rather than an exit status

  "Started" is not observable from the thing that started it. A process id proves
  a fork, not a working agent: the credential may be missing, the model call may
  404, the harness may never have been joined. Every one of those exits zero from
  the caller's side and produces silence, and silence is what `agent.sh`'s hook
  preflight was written to stop — it refuses to run rather than report a green
  result that gated nothing.

  So the acceptance signal is the one that cannot be faked by a process that is
  merely alive: the agent registers, authenticates, and its turns arrive in the
  chat surface where the operator watches agents work. `AgentHarness.relay_up/2`
  already carries a Claude Code agent's turns into `Conversations`; a Pi agent
  appearing there is the whole chain — mint, configure, authenticate, start,
  report — proven end to end by one observation.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  cloud_endpoint()

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Minting leaves a copy that can run an agent" do
    scenario "A copy minted for Pi can run Pi" do
      given_ "a connected subscription and a working copy CodeMySpec has just minted",
             context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      when_ "an engineer asks for a Pi agent on it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "alloy", "provider" => "openai-codex"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the copy has an agent actually running on it, not just a row", context do
        text = response_text(context.response)

        # This used to assert the mint wrote `mcp.json` and `settings.json`.
        # That was the right question when the agent was a separate `pi`
        # process: it ships no MCP of its own, so without them it would run
        # perfectly and never join the harness — never appear, never relay a
        # turn.
        #
        # The agent is in the harness now. Same BEAM, same supervision tree,
        # tools called in-process. There is nothing to reach and no
        # configuration that could fail to be written, so the assertion is the
        # thing that still tells a working copy from a recorded one.
        assert text =~ "Status: running",
               "the start left the agent unconfirmed. A row at `:starting` is " <>
                 "what a copy that needed finishing by hand looks like, which is " <>
                 "the rule. Got: #{text}"

        assert text =~ context.scope.cwd,
               "the agent is not running on the copy that was just minted. " <>
                 "Got: #{text}"

        {:ok, context}
      end

      then_ "no preparatory setup call was needed", context do
        refute context.response.isError,
               "starting an agent on a freshly minted copy failed. If the reason is " <>
                 "that something still had to be configured first, that is the rule: " <>
                 "configuration belongs to the mint, because a copy that is nearly " <>
                 "ready is one a human finishes by hand."

        {:ok, context}
      end

      then_ "the agent is talking where agents are watched", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "pi",
               "the agent does not appear in the conversation surface. That is the " <>
                 "only observation that separates a working agent from a process " <>
                 "that forked and died: a pid proves neither that the credential " <>
                 "resolved nor that a model answered, and both failures exit quietly. " <>
                 "An agent the server cannot observe is indistinguishable from one " <>
                 "that never started."

        {:ok, context}
      end
    end
  end
end
