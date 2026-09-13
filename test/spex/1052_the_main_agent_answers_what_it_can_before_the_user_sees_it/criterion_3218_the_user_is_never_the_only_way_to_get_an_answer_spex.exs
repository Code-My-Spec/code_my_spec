defmodule CodeMySpecSpex.Story1052.Criterion3218Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3218 — The user is never the only way to get an answer.

  The story's whole reason for existing, and the one criterion the others are
  safe to be strict about. Every other criterion here constrains the route —
  what goes up, what stays visible, who overrules whom — and the cheapest way
  to satisfy all of them at once is to send everything to the user, which is
  the behaviour this story replaces.

  The cost of getting it wrong is not latency, it is a person. An agent
  blocked on a question only the user can answer is a project that runs at
  the speed of somebody checking their inbox, and most of what agents ask is
  already written down somewhere in the project — which working copy an epic
  is on, what a criterion says, what was decided last week.

  Two Thens. The answer exists, and the asker did not have to wait on a human
  for it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question the main agent can answer is answered without the user" do
    scenario "The user is never the only way to get an answer" do
      given_ "something the project already records", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")

        {:ok, Map.put(context, :story, story)}
      end

      given_ "an agent that asks about it", context do
        id = ask(context, "Which story covers refunds reaching the ledger?", ["Tell me", "Skip"])

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the question is raised", context do
        {:ok, Map.put(context, :waiting, open_questions(context))}
      end

      then_ "the main agent answers it", context do
        assert context.waiting =~ context.question_id,
               """
               The question is not in front of the main agent at all, so it has
               no opportunity to answer anything.

               `list_open_questions` is the surface the main agent reads on its
               cadence. A question that never appears there goes to the user by
               default, which is the behaviour this story replaces.

               #{context.waiting}
               """

        reply = main_answers(context, context.question_id, context.story.title)

        refute reply.isError,
               """
               The main agent could not answer a question the project records
               the answer to.

               #{inspect(reply)}
               """

        {:ok, context}
      end

      then_ "and the agent continues without waiting on the user", context do
        answer = collect(context, context.question_id)

        assert answer =~ context.story.title,
               """
               The asking agent did not get the answer the main agent gave, so
               it is still waiting — and the only thing that can release it now
               is a person.

               An agent blocked on a question already answered is a project
               running at the speed of somebody checking their inbox.

               #{answer}
               """

        refute answer =~ ~r/(pending|waiting|not yet answered)/i,
               """
               The agent is told to keep waiting despite an answer existing.

               #{answer}
               """

        {:ok, context}
      end
    end
  end
end
