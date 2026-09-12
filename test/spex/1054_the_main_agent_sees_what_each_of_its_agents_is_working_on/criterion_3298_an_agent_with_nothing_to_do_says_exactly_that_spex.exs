defmodule CodeMySpecSpex.Story1054.Criterion3298Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3298 — An agent with nothing to do says exactly that.

  Rule: an empty queue is an answer, not a gap.

  3272 puts idle beside broken and requires them to look different. This takes
  idle on its own and requires it to look like *something* — because the failure
  here is not confusing it with a fault, it is rendering it as nothing at all
  and leaving the reader to decide what nothing means.

  That is a real difference and not a pedantic one. Beside a broken agent, idle
  is legible by contrast. Alone in a list of three working agents, an entry with
  an empty work line reads as missing information, and the main agent's next
  move is to go and check — which is the errand the story exists to remove, paid
  for the agent that needs the least attention.

  The second half of the criterion is asserted as a refutation: nothing about it
  suggests a fault. An idle agent rendered with a warning, a dash, or an empty
  field gets looked at, and the whole point of saying "nothing to do" in words
  is that it can be read and skipped.

  ## How idle is produced

  The QA role's queue is empty because nothing on this project has reached QA —
  the graph's own answer, not a flag. An implementation that reported idle from
  a field somebody sets would pass a scenario that set it and fail in
  production, where nobody does.
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

  spex "Nothing to do is said, not left blank" do
    scenario "the graph holds no work for a QA agent's role" do
      given_ "a QA agent on a checkout whose graph holds nothing for it", context do
        reply = join_working_copy(context, "/tmp/spex-3298", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # No task claimed and none available: nothing on this project has
        # reached QA, so the graph's own answer for this role is empty.
        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "qa",
            working_copy: "/tmp/spex-3298"
          )

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "it is shown as having nothing to do", context do
        assert context.view =~ context.agent.id,
               "the idle agent is not in the view at all:\n#{context.view}"

        assert context.view =~ ~r/nothing to do/i,
               """
               The idle agent's work line is blank rather than saying it has
               none.

               Beside a broken agent, idle is legible by contrast — that is
               criterion 3272 and it would pass. Alone in a list of working
               agents, an empty line reads as missing information, and the main
               agent's next move is to go and check. That errand is the one the
               story exists to remove, and it is being paid for the agent that
               needs the least attention.

               view:
               #{context.view}
               """

        {:ok, context}
      end

      then_ "and nothing about it suggests a fault", context do
        refute context.view =~ ~r/\b(stalled|stuck|dead|error|fault|unable|failed)\b/i,
               """
               An idle agent is being flagged as though something were wrong.

               An empty queue is the healthy end of a project's work, not a
               condition. An agent rendered with a warning gets looked at, and
               the whole reason to say "nothing to do" in words is that it can
               be read and skipped.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
