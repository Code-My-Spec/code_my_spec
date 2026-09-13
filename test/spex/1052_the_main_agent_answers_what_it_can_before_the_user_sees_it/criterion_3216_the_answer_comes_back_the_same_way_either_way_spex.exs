defmodule CodeMySpecSpex.Story1052.Criterion3216Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3216 — The answer comes back the same way either way.

  What makes the routing an implementation detail rather than a second thing
  agents have to understand. An agent calls `ask_user_question` and later
  `check_answer`; who filled the answer in between is not its business, and
  building it so that it were would mean every agent carries a branch for a
  decision made above it.

  Two agents, two questions, two different answerers, one delivery mechanism.
  The pair is the claim: one question answered by each route, collected the
  same way, and — the part that actually breaks — each agent getting *its own*
  answer rather than the other's.

  Crossed answers are the failure worth writing a scenario for. With one
  question in flight any delivery looks correct; with two, a lookup keyed on
  the wrong thing hands an agent a confident answer to a question it never
  asked, and nothing about the reply says so.
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

  spex "Who answered is not something the asking agent has to know" do
    scenario "The answer comes back the same way either way" do
      given_ "two agents, each having asked a question", context do
        first = ask(context, "Which checkout is the refunds epic built on?", ["Tell me"])

        second =
          ask(context, "Should refunds older than ninety days be allowed?", ["Allow", "Refuse"])

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      given_ "the main agent answered one and the user answered the other", context do
        reply = main_answers(context, context.first, "the refunds epic is on /tmp/refunds-copy")

        refute reply.isError,
               "the premise needs one question answered by the main agent"

        :ok = user_answers(context, context.second, "Refuse")

        {:ok, context}
      end

      when_ "each answer is delivered", context do
        {:ok,
         context
         |> Map.put(:first_answer, collect(context, context.first))
         |> Map.put(:second_answer, collect(context, context.second))}
      end

      then_ "each agent receives the answer to its own question", context do
        assert context.first_answer =~ "refunds epic is on /tmp/refunds-copy",
               """
               The agent that asked about the checkout did not get the main
               agent's answer to it.

               #{context.first_answer}
               """

        assert context.second_answer =~ "Refuse",
               """
               The agent that asked about the refund window did not get the
               user's answer to it.

               #{context.second_answer}
               """

        refute context.first_answer =~ "Refuse",
               """
               The first agent was handed the *other* question's answer.

               This is the failure two questions exist to catch: with one in
               flight any delivery looks correct, and a lookup keyed on the
               wrong thing gives an agent a confident answer to something it
               never asked, with nothing in the reply to say so.

               #{context.first_answer}
               """

        {:ok, context}
      end

      then_ "and neither needs to know which of them answered it", context do
        assert String.length(context.first_answer) > 0 and
                 String.length(context.second_answer) > 0,
               "one of the two collected nothing at all"

        refute context.first_answer =~ ~r/(ask the user|escalate|check the inbox)/i,
               """
               The main agent's answer came back telling the agent to go and do
               something else to get it, so the two routes are not one
               mechanism after all.

               #{context.first_answer}
               """

        {:ok, context}
      end
    end
  end
end
