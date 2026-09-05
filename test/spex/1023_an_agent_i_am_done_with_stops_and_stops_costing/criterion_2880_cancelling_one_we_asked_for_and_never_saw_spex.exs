defmodule CodeMySpecSpex.Story1023.Criterion2880Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2880 — Cancelling one we asked for and never saw.

  Rule: An agent that never came up can still be stopped.

  `:starting` means "we asked and no machine has confirmed" — a real state, and
  the one an agent sits in whenever its copy's harness is offline at the moment
  it was requested. The working copies page renders it as *we asked for this
  one; no harness has confirmed it*.

  Those rows have to be cancellable. An agent that cannot be stopped because it
  never started is a row the operator can neither use nor remove, and it keeps
  claiming a lane on the page.

  There is no process here, so there is nothing to signal and nothing to
  confirm — which is why this must not be routed through the machine at all. A
  stop that asked an unreachable harness about a process that never existed
  would fail, and the failure would be about the harness rather than about the
  agent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent nothing confirmed can still be cancelled" do
    scenario "Cancelling one we asked for and never saw" do
      given_ "an agent I asked for that no machine has confirmed, with no process id recorded",
             context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :zai)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, started, _frame} =
          StartAgent.execute(
            %{"engine" => "alloy", "provider" => "zai", "working_copy" => "/tmp/never-came-up"},
            frame
          )

        refute started.isError,
               "the premise is an agent that was asked for: #{response_text(started)}"

        {:ok, Map.put(context, :started, started)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)

        agent_id =
          Regex.run(
            ~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/,
            response_text(listing)
          )
          |> case do
            [id | _] -> id
            _ -> flunk("no agent in the listing: #{response_text(listing)}")
          end

        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => agent_id}, frame)

        {:ok, context |> Map.put(:reply, reply) |> Map.put(:agent_id, agent_id)}
      end

      then_ "it stops being listed as starting", context do
        refute context.reply.isError,
               "an agent that never came up could not be cancelled: " <>
                 "#{response_text(context.reply)}. That leaves a row the operator " <>
                 "can neither use nor remove, still claiming a lane on the page."

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, after_stop, _frame} = ListAgents.execute(%{}, frame)

        refute response_text(after_stop) =~ context.agent_id,
               "the agent is still listed after being stopped. " <>
                 "Got: #{response_text(after_stop)}"

        {:ok, context}
      end

      then_ "and nothing reports an error about a process that never existed", context do
        refute response_text(context.reply) =~ ~r/harness|not connected|process/i,
               "the cancel was routed through a machine and reported a problem " <>
                 "with reaching it. There is no process here — the failure would " <>
                 "be about the harness rather than about the agent, and would make " <>
                 "an unconfirmed agent uncancellable exactly when its machine is " <>
                 "down, which is why it is unconfirmed. Got: " <>
                 response_text(context.reply)

        {:ok, context}
      end
    end
  end
end
