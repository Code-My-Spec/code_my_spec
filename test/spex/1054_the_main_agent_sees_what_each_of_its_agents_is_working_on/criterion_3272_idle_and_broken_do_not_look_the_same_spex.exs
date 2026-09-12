defmodule CodeMySpecSpex.Story1054.Criterion3272Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3272 — Idle and broken do not look the same.

  Rule: an agent doing nothing says which kind of nothing it is.

  From the outside the two are identical — no task, no turns, no messages — and
  they want opposite responses. An idle agent should be left alone; a broken one
  should be restarted or its machine fixed, which is story 1056. Told apart
  wrongly in either direction the cost is real and silent: restarting an idle
  agent is churn, and leaving a broken one is an agent that will never work
  again and never say so.

  This is the criterion that makes the rest of the story worth building. A view
  that says "nothing" about both is no better than the empty transcript the main
  agent already had.

  ## The two conditions, and why each is produced rather than asserted into

  Idle is the graph holding no work for the role — the QA agent here has none
  because nothing on this project has reached QA. Broken is the machine
  reporting no tools, which is what `WorkingCopies.record_machine_tools/2` says
  and what an agent whose harness has lost its MCP client actually looks like:
  the process is alive, the row says running, and every tool call fails.

  That second one is the outage this story came from. A stale MCP client held by
  the harness VM told a live agent its tools did not exist, no agent could see
  it, and it took four hours and raw JSON-RPC to find.

  The reason is asserted as well as the state. "Unable to work" with no account
  of why sends the main agent to the same place it would have gone anyway.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Nothing to do and cannot work are different answers" do
    scenario "one agent has an empty queue and another has lost its tools" do
      given_ "an idle QA agent on one checkout and a toolless coding agent on another",
             context do
        idle_reply = join_working_copy(context, "/tmp/spex-3272-idle", "the idle checkout")
        idle_scope = %{context.scope | active_working_copy_id: idle_reply.working_copy_id}

        # Nothing on this project has reached QA, so the graph holds no work for
        # this role. Idle is produced rather than declared.
        idle =
          CodeMySpecSpex.Fixtures.running_agent(idle_scope,
            role: "qa",
            working_copy: "/tmp/spex-3272-idle"
          )

        broken_reply = join_working_copy(context, "/tmp/spex-3272-broken", "the broken checkout")
        broken_scope = %{context.scope | active_working_copy_id: broken_reply.working_copy_id}

        broken =
          CodeMySpecSpex.Fixtures.running_agent(broken_scope,
            role: "coding",
            working_copy: "/tmp/spex-3272-broken"
          )

        # A machine that answers "I can do nothing" is what a harness holding a
        # stale MCP client looks like from here: alive, joined, and unable to
        # call anything.
        CodeMySpecSpex.Fixtures.record_machine_tools(broken_scope, [])

        {:ok,
         context
         |> Map.put(:scope, idle_scope)
         |> Map.put(:idle, idle)
         |> Map.put(:broken, broken)}
      end

      when_ "the main agent looks at what its agents are doing", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the idle one has nothing to do and the broken one cannot work", context do
        assert context.view =~ ~r/nothing to do/i,
               """
               The idle agent is not shown as having nothing to do.

               view:
               #{context.view}
               """

        assert context.view =~ ~r/cannot work|unable to work/i,
               """
               The agent that cannot reach its tools is not shown as unable to
               work.

               From the outside it is identical to the idle one beside it — no
               task, no turns, nothing said — and the two want opposite
               responses. This is the outage the story came from: a stale MCP
               client told a live agent its tools did not exist, and nothing
               anywhere could see it.

               view:
               #{context.view}
               """

        assert context.view =~ ~r/tools/i,
               """
               The broken agent is shown as unable to work with no reason given.

               "Cannot work" and nothing else sends the main agent to go and
               find out, which is the errand it was meant to be spared. The
               remedy for lost tools is not the remedy for anything else that
               stops an agent.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
