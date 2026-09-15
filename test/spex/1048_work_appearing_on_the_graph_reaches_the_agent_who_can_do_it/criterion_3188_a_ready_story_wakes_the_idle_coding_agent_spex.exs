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
  alias CodeMySpecSpex.StoryHelpers
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

      given_ "a story interviewed and linked, but not yet released", context do
        # Parked, linked and interviewed, so releasing it is the one thing left
        # and what it puts on the graph is `bdd_specs_exist` — coding's.
        #
        # A bare released story projects `component_linked` and
        # `three_amigos_complete`, both product's, so the coding lane never
        # moved and "the agent was told nothing" was the right answer to a
        # scenario that had put nothing there. `create_story` also releases by
        # default, which is why this says otherwise explicitly.
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "Interviewed and waiting to be released",
            acceptance_criteria: ["A refund lands on the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        {:ok, Map.put(context, :story, story)}
      end

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
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
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
        # The directive line, not the whole message. Every menu ends with the
        # same standing offers, two of which say `ask_user_question` and "once
        # a human approves" — offered to every agent on every turn as things it
        # *may* do. Matching those as gatekeeping makes the criterion
        # unsatisfiable by any menu at all, which is a claim about the
        # boilerplate rather than about this wake. Same correction as 3193.
        directives = Enum.map(context.said, &(&1 |> String.split("\n\n") |> Enum.at(1, "")))

        refute Enum.any?(directives, &(&1 =~ ~r/(waiting for|approval|sign.?off|permission)/i)),
               """
               The wake makes the agent wait on somebody before it may act.

               "Without a person routing it" is the clause that makes this a
               product rather than a queue: an agent that needs a human in the
               loop to start is exactly as fast as the human.

               #{Enum.join(directives, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
