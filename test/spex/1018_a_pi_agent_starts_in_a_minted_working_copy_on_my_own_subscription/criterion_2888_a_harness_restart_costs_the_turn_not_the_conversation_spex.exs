defmodule CodeMySpecSpex.Story1018.Criterion2888Spex do
  @moduledoc """
  Story 1018 — An agent starts in a minted working copy on my own subscription.
  Criterion 2888 — A harness restart costs the turn, not the conversation.

  Rule: An agent that went down with its harness comes back with its
  conversation and keeps going.

  What "keeps going" has to mean. An agent that came back with no memory would
  satisfy a naive reading — there is a process, on the right checkout, under the
  right id — and be useless: it would restart the story from nothing, redo work
  already done, and charge for it.

  The conversation is what makes coming back cheap rather than merely possible.
  It is also why this was expensive with a detached OS process and is not now:
  resurrecting one meant a group id and the boot it belonged to, and the
  transcript lived in the process. Here the transcript is already ours — a
  restore is starting a process with the history it had.

  A turn in flight is genuinely lost. That is the honest cost and the criterion
  says so: the *turn*, not the conversation.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coming back is cheap because the transcript is ours" do
    scenario "A harness restart costs the turn, not the conversation" do
      given_ "an agent with a conversation on its working copy", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        # Started through the tool an operator uses, because opening the
        # conversation is part of starting — writing the row directly would give
        # an agent with nothing to preserve, which is the premise, not the test.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        refute response.isError, response_text(response)

        agent = context.scope |> Fixtures.list_agents() |> List.first()
        copy = agent.working_copy

        conversation = Fixtures.agent_conversation(context.scope, agent)

        assert conversation,
               "the premise is an agent whose work is recorded somewhere; without " <>
                 "a conversation there is nothing for coming back to preserve"

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:copy, copy)
         |> Map.put(:conversation, conversation)}
      end

      when_ "its harness goes down and is told what to bring back", context do
        :ok = stop_agent_process(context.agent.id)
        {:ok, _} = restore_agent(context.agent.id, context.copy)

        {:ok, context}
      end

      then_ "the agent is running again", context do
        assert running?(context.agent.id),
               "it did not come back, so the conversation it kept is attached to " <>
                 "nothing"

        {:ok, context}
      end

      then_ "and its conversation is the one it had, not a new one", context do
        after_restart = Fixtures.agent_conversation(context.scope, context.agent)

        assert after_restart.id == context.conversation.id,
               "it came back against a fresh conversation. Everything it had " <>
                 "already worked out is gone from its view, so it starts the story " <>
                 "again — redoing work that was done and charging for it. Was " <>
                 "#{context.conversation.id}, now #{after_restart.id}."

        {:ok, context}
      end
    end
  end
end
