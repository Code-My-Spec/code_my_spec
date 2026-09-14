defmodule CodeMySpecSpex.Story1052.Criterion3219Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3219 — The agent can tell who answered.

  Next to 3216 and not in tension with it, though it reads that way at first.
  3216 says the agent must not have to *know* who answered in order to collect
  — one mechanism, no branch. This says the answer must *say*, once collected.

  The difference is between routing and weight. The delivery is uniform; what
  the answer is worth is not. A main agent's answer is a reading of the
  project's records and can be wrong about intent; the user's is the intent
  itself. An agent that treats both identically will argue with the user's
  answer on the strength of something it was told earlier by a peer.

  It is also what makes 3220 expressible at all: "the user's answer is the one
  that stands" is a rule about precedence, and precedence needs the agent to be
  able to see which it is holding.
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

  spex "An answer says where it came from" do
    scenario "The agent can tell who answered" do
      given_ "an agent that asked a question", context do
        by_main = ask(context, "Which checkout is the refunds epic built on?", ["Tell me"])

        by_user =
          ask(context, "Should refunds older than ninety days be allowed?", ["Allow", "Refuse"])

        {:ok, context |> Map.put(:by_main, by_main) |> Map.put(:by_user, by_user)}
      end

      when_ "the answer arrives", context do
        reply = main_answers(context, context.by_main, "/tmp/refunds-copy")
        refute reply.isError, "the premise needs one answered by the main agent"

        :ok = user_answers(context, context.by_user, "Refuse")

        {:ok,
         context
         |> Map.put(:from_main, collect(context, context.by_main))
         |> Map.put(:from_user, collect(context, context.by_user))}
      end

      then_ "it names whether the main agent or the user answered it", context do
        assert context.from_main =~ ~r/(main agent|answered by the main)/i,
               """
               An answer the main agent gave does not say so.

               Delivery being uniform (3216) is not the same as the answers
               being worth the same. A main agent's answer is a reading of the
               project's records and can be wrong about intent; the user's is
               the intent. An agent that cannot tell them apart will argue with
               the user on the strength of something a peer told it earlier.

               #{context.from_main}
               """

        assert context.from_user =~ ~r/(the user|you answered|answered by the user)/i,
               """
               An answer the user gave does not say so, so the agent cannot
               know it is holding the decision rather than a reading of it.

               This is also what makes 3220 expressible: "the user's answer is
               the one that stands" is a rule about precedence, and precedence
               needs the agent to see which it has.

               #{context.from_user}
               """

        {:ok, context}
      end
    end
  end
end
