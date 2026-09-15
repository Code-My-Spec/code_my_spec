defmodule CodeMySpecSpex.Story1052.Criterion3214Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3214 — A product decision goes up to the user.

  The counterweight to 3218. That one says the main agent answers what it can;
  this says there is a class it must not, and hands up instead.

  The line is not difficulty, it is authority. "Which working copy is this epic
  on" has an answer in the project. "Should we build this at all" has no answer
  anywhere — it is a decision, and a main agent that makes it has decided the
  product on the user's behalf, silently, in a reply the user never sees.

  The second Then is the one with teeth and the reason `escalate_question`
  takes an `as`. A question that arrives as the agent's own words — module
  names, criterion ids, a spex path — is one the user has to decode before they
  can decide, and the whole point of routing through the main agent is that it
  can translate. Escalating verbatim is passing the interruption along without
  the work that justified it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question only the user can decide reaches the user, in their terms" do
    scenario "A product decision goes up to the user" do
      given_ "a coding agent asking whether an unbuilt feature should be built", context do
        id =
          ask(
            context,
            "CodeMySpec.Billing.Dunning does not exist. Should retries on a failed " <>
              "card be built, or should the charge just fail?",
            ["Build retries", "Let it fail"]
          )

        {:ok, Map.put(context, :question_id, id)}
      end

      when_ "the main agent cannot decide it", context do
        reply =
          main_escalates(
            context,
            context.question_id,
            "Whether to retry a failed card is a product decision — nothing in " <>
              "the project records it and it changes what customers experience.",
            "When someone's card is declined, should we try again over the next " <>
              "few days, or tell them straight away that the payment failed?"
          )

        {:ok, context |> Map.put(:reply, reply) |> Map.put(:text, response_text(reply))}
      end

      then_ "the question reaches the user", context do
        refute context.reply.isError,
               """
               The main agent could not hand a product decision up, so the
               question stops with the one party that must not decide it.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and it is put in terms the user can decide on without reading code", context do
        # The main agent's own section, not the whole listing. An escalated
        # question stays listed under "Waiting on the user" by design — that is
        # `MainAgentMapper`'s whole reason for having two sections — so reading
        # the page cannot tell "still mine" from "handed up and shown as such".
        mine = mine_to_answer(context)

        refute mine =~ context.question_id,
               """
               The escalated question is still sitting in the main agent's own
               queue, so "reaches the user" is true of nothing.

               #{mine}
               """

        refute context.text =~ "CodeMySpec.Billing.Dunning",
               """
               The question went up carrying the agent's own words — a module
               name the user would have to go and read code to understand.

               `escalate_question` takes an `as` precisely so this does not
               happen: routing through the main agent is only worth the hop if
               it translates. Passing the agent's phrasing straight through is
               the interruption without the work that justified it.

               #{context.text}
               """

        {:ok, context}
      end
    end
  end
end
