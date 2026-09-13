defmodule CodeMySpecSpex.Story1050.Criterion3202Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3202 — Any agent may run a spex, whoever was told about it.

  The line between notification and permission, drawn on the operation where
  confusing the two hurts most.

  A coding agent that has just changed code needs to run the spex to know
  whether it broke anything. If running one were scoped to whoever was notified
  about it, the coding agent would have to ask QA to check its own work — and
  the obvious implementation of every other criterion on this story does
  exactly that, because "only tell the role that owns it" and "only let the
  role that owns it" are one `if` apart.

  So the role filter has to live in the routing and nowhere else. The whole
  story is about attention, not authority: what an agent is *shown* is scoped;
  what it may *do* is not.

  3226 is this rule stated in general; this is the specific case that
  demonstrates why it matters.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.StartAnalysis
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The role filter scopes what an agent is told, never what it may do" do
    scenario "Any agent may run a spex, whoever was told about it" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a spex needing to run, and the QA agent told about it", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        qa = Fixtures.running_agent(context.scope, role: "qa")
        context = context |> start_session() |> put_to_work()

        story = Fixtures.released_story(context.scope, "Refunds reach the ledger")
        Fixtures.record_deploy(context.scope, story.id, "dev")
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context |> Map.put(:coding, coding.id) |> Map.put(:qa, qa.id)}
      end

      when_ "the coding agent runs that spex", context do
        {:reply, reply, _frame} = StartAnalysis.execute(%{source: "spex"}, frame(context))

        {:ok, context |> Map.put(:reply, reply) |> Map.put(:text, response_text(reply))}
      end

      then_ "it is allowed to", context do
        refute context.reply.isError,
               """
               A coding agent was refused a spex run.

               It has just changed code and needs to know whether it broke
               anything. Refused, the only route left is asking QA to check its
               own work — which is a handoff inserted between an agent and the
               feedback on its own turn.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and nothing refuses the run on the grounds of its role", context do
        refute context.text =~ ~r/(role|not your|qa agent|permission|not allowed)/i,
               """
               The run was refused, or hedged, on the grounds of the agent's
               role.

               "Only tell the role that owns it" and "only let the role that
               own it" are one `if` apart, which is why this is a criterion
               rather than an assumption. The whole story is about attention,
               not authority: what an agent is shown is scoped, what it may do
               is not.

               #{context.text}
               """

        {:ok, context}
      end
    end
  end
end
