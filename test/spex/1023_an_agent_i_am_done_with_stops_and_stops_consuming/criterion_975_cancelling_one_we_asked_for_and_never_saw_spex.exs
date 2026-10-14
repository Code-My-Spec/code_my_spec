defmodule CodeMySpecSpex.Story1023.Criterion975Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 975 — Cancelling one we asked for and never saw.

  Rule: Stopping an agent no machine ever confirmed is not a failure.

  An agent that was asked for and never reported present has no process
  anywhere to end. Treating that the same as a machine that refused to end a
  real one is how cancelling a request that went nowhere turns into an error
  about a process that never existed.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, response_field: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpec.McpServers.Agents.Tools.TurnOffAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Cancelling a request no machine confirmed is not a failure", criterion: 975 do
    scenario "Cancelling one we asked for and never saw" do
      given_ "an agent I asked for that no machine has confirmed, with no process id recorded",
             context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, started, _frame} =
          StartAgent.execute(
            %{"engine" => "alloy", "provider" => "openai-codex", "working_copy" => "copy-never-seen"},
            frame
          )

        refute started.isError, response_text(started)

        agent_id = response_field(started, "Agent")

        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)

        assert response_text(listing) =~ agent_id,
               "the premise is an agent on record that no machine has confirmed; without " <>
                 "one this asserts nothing about cancelling a request that went nowhere"

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = TurnOffAgent.execute(%{"agent_id" => context.agent_id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it stops being listed as starting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)

        refute response_text(listing) =~ context.agent_id,
               "the agent is still listed after being cancelled — a request that went " <>
                 "nowhere should not go on looking like one still starting"

        {:ok, context}
      end

      then_ "and nothing reports an error about a process that never existed", context do
        refute context.reply.isError,
               "cancelling a request no machine ever confirmed reported an error — " <>
                 "treating it the same as a real process that refused to end is how a " <>
                 "request that went nowhere becomes a failure. Got: " <>
                 response_text(context.reply)

        {:ok, context}
      end
    end
  end
end
