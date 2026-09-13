defmodule CodeMySpecSpex.Story1050.Criterion3227Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3227 — Two agents of the same role on one working copy are not told
  twice over.

  Every other criterion here routes by role and checkout. This is the case
  where both are identical and the pair is still two agents — so role and
  checkout are not enough to decide who does the work, and something else has
  to.

  Story 1023's rule allows several agents on a copy, so this is a configuration
  the product supports rather than a mistake to refuse. What it cannot support
  is both of them starting the same thing: two agents editing one tree is the
  failure the working-copy grain exists to prevent, and here they are in the
  same tree by design.

  The criterion asks for ownership rather than for silence, and that is the
  distinction worth keeping. Telling only one of them and leaving the other
  guessing is not the answer either — the second agent has to be able to find
  out that the work is held, which is what makes "not worked twice" survive the
  second agent going looking on its own.

  1048's 3197 is the same collision from the loser's side: there the work is
  gone by the time it wakes, and the requirement is that it goes quietly back
  to idle.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Two agents of one role on one copy do not both take the work" do
    scenario "Two agents of the same role on one working copy are not told twice over" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "two coding agents running on the same working copy", context do
        first = Fixtures.running_agent(context.scope, role: "coding")
        second = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:first, first.id)
         |> Map.put(:second, second.id)
         |> Map.put(:first_before, heard_count(context, first.id))
         |> Map.put(:second_before, heard_count(context, second.id))}
      end

      when_ "coding work appears there", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.mark_story_ready(context.scope, story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :story, story)}
      end

      then_ "the work is not worked twice", context do
        woken =
          Enum.count(
            [
              {context.first, context.first_before},
              {context.second, context.second_before}
            ],
            fn {id, before} -> heard_count(context, id) > before end
          )

        assert woken <= 1,
               """
               Both coding agents on one checkout were told to do the same
               work.

               Role and checkout are identical here, so neither filter decides
               between them — and both starting it is two agents editing one
               tree, which is the failure the working-copy grain exists to
               prevent. Story 1023 allows several agents on a copy, so this is
               a configuration the product supports rather than a mistake to
               refuse.
               """

        assert woken == 1,
               """
               Neither agent was told, so the work sits on a staffed checkout
               with two agents on it and nobody acting.

               "Not twice" must not be achieved by "not at all".
               """

        {:ok, context}
      end

      then_ "and it is clear which agent owns it", context do
        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame(context))
        report = response_text(view)

        assert report =~ Regex.escape(context.story.title),
               """
               Nothing says which of the two agents holds this story.

               Telling one and leaving the other guessing is not the answer
               either: the second agent has to be able to find out the work is
               held, which is what makes "not worked twice" survive it going
               looking on its own.

               #{report}
               """

        {:ok, context}
      end
    end
  end
end
