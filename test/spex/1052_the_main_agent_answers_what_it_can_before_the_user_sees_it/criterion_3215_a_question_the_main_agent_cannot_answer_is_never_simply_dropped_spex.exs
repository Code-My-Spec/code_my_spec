defmodule CodeMySpecSpex.Story1052.Criterion3215Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3215 — A question the main agent cannot answer is never simply
  dropped.

  Putting a router between an agent and the user creates somewhere for a
  question to stop. Nothing else on this story covers that: 3214 is about a
  question the main agent correctly hands up, and 3218 is one it correctly
  answers. This is the third outcome — it does neither — and it is the one with
  no visible symptom.

  A dropped question costs more than an unanswered one. The asking agent is
  still waiting, so it looks busy; the user was never told, so their inbox is
  clean; and the main agent has moved on. Every surface reads healthy and the
  work has stopped.

  "Either with the user or visibly waiting to go there" is deliberately the
  weaker of the two, and it is what makes this checkable without deciding the
  routing's internals. What it rules out is the third state: gone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question the main agent cannot answer is never simply dropped" do
    scenario "A question the main agent cannot answer is never simply dropped" do
      given_ "an agent asking something the main agent cannot answer", context do
        id =
          ask(
            context,
            "Should a refund older than ninety days still be allowed?",
            ["Allow it", "Refuse it"]
          )

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the main agent has no answer of its own", context do
        # It does the honest thing and says so, rather than inventing one.
        reply =
          main_escalates(
            context,
            context.question_id,
            "Nothing in the project records a refund window; this is a policy " <>
              "decision rather than a fact I can look up."
          )

        {:ok, context |> Map.put(:reply, reply) |> Map.put(:text, response_text(reply))}
      end

      then_ "the question is still open", context do
        answer = collect(context, context.question_id)

        refute answer =~ ~r/(not found|no such question|unknown)/i,
               """
               The question is gone. The asking agent asks for it and nothing
               has it.

               This is the expensive failure on this criterion, because every
               surface reads healthy: the agent is still waiting so it looks
               busy, the user was never told so their inbox is clean, and the
               main agent has moved on. The work has simply stopped.

               #{answer}
               """

        {:ok, Map.put(context, :answer, answer)}
      end

      then_ "and it is either with the user or visibly waiting to go there", context do
        {:reply, listed, _frame} = ListUserQuestions.execute(%{}, frame(context))
        inbox = response_text(listed)
        waiting = open_questions(context)

        assert inbox =~ context.question_id or waiting =~ context.question_id,
               """
               The question is in neither place — not with the user, and not
               queued anywhere that says it is going there.

               This is the weaker of the two halves on purpose: it does not
               decide how the routing works, only that the third state — gone —
               is not one of the outcomes.

               user's inbox:
               #{inbox}

               waiting on the main agent:
               #{waiting}
               """

        {:ok, context}
      end
    end
  end
end
