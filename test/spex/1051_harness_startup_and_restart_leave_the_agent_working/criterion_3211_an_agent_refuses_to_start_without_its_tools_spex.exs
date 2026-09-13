defmodule CodeMySpecSpex.Story1051.Criterion3211Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3211 — An agent refuses to start without its tools.

  Rule: An agent whose tools do not resolve fails loudly instead of running.

  `CodeMySpec.Agents` already argues this for credentials, in its own words:
  "an agent started without a working credential fails on its first model call
  — minutes later, in a log nobody is reading". Tools are the same shape and
  currently get the opposite treatment. `launch/2` falls to `keep_starting/2`,
  which logs at info and leaves the row `:starting` — "asked-for and
  unconfirmed", which is a true description of a state nothing will ever
  change.

  The three Thens fail separately and the middle one is the one with teeth. Not
  reaching a running state is already true; being *reported as failed, with the
  reason* is not, and it is the difference between an operator who knows to go
  and look at the machine and one who watches a spinner.

  ## How the premise is made

  Through the machine being out of reach, which is the honest way to get an
  agent whose tools do not resolve: tool resolution happens where the agent
  starts, so a machine that cannot be reached is a machine that resolved
  nothing. Blinding it any closer would mean reaching inside `launch/2` and
  asserting about the seam rather than about the agent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [machine_out_of_reach: 0, running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent whose tools do not resolve fails loudly instead of running" do
    scenario "An agent refuses to start without its tools" do
      given_ "an agent's tools cannot be resolved at launch", context do
        context = given_a_staffed_checkout(context, "spex_3211")
        machine_out_of_reach()

        {:ok, context}
      end

      when_ "the agent is started", context do
        {:reply, reply, _frame} =
          StartAgent.execute(
            %{role: "coding", working_copy_id: context.copy_id},
            frame(context)
          )

        {:ok,
         context
         |> Map.put(:reply, reply)
         |> Map.put(:text, response_text(reply))
         |> Map.put(:agent_id, agent_id_in(response_text(reply)))}
      end

      then_ "it does not reach a running state", context do
        refute context.agent_id && running?(context.agent_id),
               """
               An agent whose tools never resolved is running.

               Every tool call it makes will fail, and it will make them for as
               long as somebody keeps giving it work — which is the four hours
               in this story's note.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and it is reported as failed with the reason", context do
        assert context.reply.isError,
               """
               Starting answered success for an agent that did not start.

               The caller has no way to tell this from a working agent except
               by watching it not work. `keep_starting/2` logs the reason at
               info and leaves the row `:starting` — "asked-for and
               unconfirmed" — which nothing will ever change and nothing is
               watching.

               #{context.text}
               """

        assert context.text =~ ~r/(tool|machine|harness|reach)/i,
               """
               The refusal does not say what was wrong, so it sends nobody
               anywhere. `AgentsMapper` keeps `:not_connected` and
               `:reconnect_required` apart for exactly this reason — a refusal
               that names the wrong cause sends someone to set up something
               that already exists.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and it is never shown as running or idle", context do
        listed = listing(context)

        refute listed =~ ~r/Status: (running|idle)/,
               """
               The project's own listing shows the agent as running or idle.

               This is the surface an operator and the main agent both read, so
               an agent that never came up and reads as healthy here is one
               nobody will go and look at.

               #{listed}
               """

        {:ok, context}
      end
    end
  end
end
