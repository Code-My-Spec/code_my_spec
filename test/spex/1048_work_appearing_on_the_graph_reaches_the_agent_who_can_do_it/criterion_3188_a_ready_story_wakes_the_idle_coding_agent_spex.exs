defmodule CodeMySpecSpex.Story1048.Criterion3188Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3188 — A ready story wakes the idle coding agent.

  The story's own sentence, minus the last clause: "without a person routing
  it". That clause is the whole product. An agent that starts on the right
  thing once somebody tells it to is a person's queue with extra steps, and the
  person is the bottleneck this exists to remove.

  Sits beside story 1047's 3178, which asserts the same doorbell from the
  "leave idle agents alone" side. They are the same mechanism seen from two
  stories, and they are both here because the mechanism has two ways to be
  wrong — ringing when it should not, and not ringing when it should — and
  neither story's criteria catch the other's failure.

  Three Thens. The message arrives; it says what for; and nothing external had
  to route it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work appearing inside an agent's role and copy reaches that agent" do
    scenario "A ready story wakes the idle coding agent" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent running and idle on its working copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()

        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "a story on that working copy becomes ready for coding", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.mark_story_ready(context.scope, story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :story, story)}
      end

      then_ "the agent receives a message naming that work", context do
        said = said_since(context, context.coding, context.before)

        refute said == [],
               """
               Work the agent can do appeared on its own checkout and it was
               told nothing.

               An idle agent has nothing that would ever bring it back on its
               own — the copy stays staffed, switched on, and asleep until a
               person notices and routes the work, which is the bottleneck this
               story exists to remove.
               """

        assert Enum.any?(
                 said,
                 &(&1 =~ ~r/(get_next_requirement|#{Regex.escape(context.story.title)})/)
               ),
               """
               The agent was woken and not told what for, so it spends a turn
               working out why.

               #{Enum.join(said, "\n---\n")}
               """

        {:ok, Map.put(context, :said, said)}
      end

      then_ "and it begins a turn without a person routing it", context do
        refute Enum.any?(context.said, &(&1 =~ ~r/(ask|waiting for|approval|confirm)/i)),
               """
               The wake asks somebody before the agent may act on it.

               "Without a person routing it" is the clause that makes this a
               product rather than a queue: an agent that needs a human in the
               loop to start is exactly as fast as the human.

               #{Enum.join(context.said, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
