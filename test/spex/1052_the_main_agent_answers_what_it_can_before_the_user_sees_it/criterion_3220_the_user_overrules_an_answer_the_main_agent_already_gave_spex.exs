defmodule CodeMySpecSpex.Story1052.Criterion3220Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3220 — The user overrules an answer the main agent already gave.

  What 3217's visibility is *for*. Seeing that the main agent answered is only
  worth anything if disagreeing with it changes something.

  The ordering is the hard part and it is why this is its own criterion. The
  main agent answered first, so by the time the user reads it the agent may
  have acted already. Nothing here can undo that, which is exactly why the
  second Then exists: the agent has to be told it was superseded, and by whom,
  because an agent that simply receives a different answer to a question it
  considers closed has no reason to revisit what it did on the strength of the
  first one.

  "And by whom" is not decoration. 3219 establishes that a user's answer
  outranks a main agent's; without the attribution the supersession is just a
  second opinion, and the agent has no basis for preferring it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The user's answer outranks the main agent's, and the agent is told" do
    scenario "The user overrules an answer the main agent already gave" do
      given_ "the main agent answered an agent's question", context do
        id =
          ask(context, "Should refunds older than ninety days be allowed?", ["Allow", "Refuse"])

        reply = main_answers(context, id, "Allow — nothing in the records sets a window.")

        refute reply.isError, "the premise is a question the main agent answered"

        {:ok, Map.put(context, :question_id, id)}
      end

      given_ "the user then answers the same question differently", context do
        :ok = user_answers(context, context.question_id, "Refuse")

        {:ok, context}
      end

      when_ "both answers exist", context do
        {:ok, Map.put(context, :answer, collect(context, context.question_id))}
      end

      then_ "the user's answer is the one that stands", context do
        assert context.answer =~ "Refuse",
               """
               The agent is still holding the main agent's answer after the
               user gave a different one.

               This is what 3217's visibility is for: seeing that the main
               agent answered is worth nothing if disagreeing changes nothing.

               #{context.answer}
               """

        refute context.answer =~ "nothing in the records sets a window",
               """
               The superseded answer is still what the agent reads as current.

               #{context.answer}
               """

        {:ok, context}
      end

      then_ "and the agent is told it was superseded and by whom", context do
        assert context.answer =~ ~r/(supersede|replaced|overrul|changed)/i,
               """
               The agent receives a different answer with nothing saying an
               earlier one existed.

               The main agent answered first, so the agent may already have
               acted on it. Nothing here can undo that — which is precisely why
               it has to be told: an agent that simply receives a new answer to
               a question it considers closed has no reason to revisit what it
               did on the strength of the old one.

               #{context.answer}
               """

        assert context.answer =~ ~r/(the user|you)/i,
               """
               The supersession does not say who did it, so it reads as a
               second opinion rather than a decision.

               3219 establishes that a user's answer outranks a main agent's.
               Without the attribution the agent has no basis for preferring
               this one.

               #{context.answer}
               """

        {:ok, context}
      end
    end
  end
end
