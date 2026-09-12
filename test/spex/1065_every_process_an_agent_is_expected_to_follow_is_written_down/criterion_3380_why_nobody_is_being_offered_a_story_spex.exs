defmodule CodeMySpecSpex.Story1065.Criterion3380Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3380 — Why nobody is being offered a story.

  The rule:

  > The document names what makes a story visible to an agent, and what makes
  > it invisible.

  ## The thing this criterion is about

  Two different conditions produce one indistinguishable symptom. A story that
  is not ready for development reports `0/0 satisfied`. A story that is ready
  but assigned to another checkout reports `0/0 satisfied`. From outside they
  are the same sentence, and neither says which it is.

  On 2026-09-12 that cost a wrong conclusion twice in one session: story 966
  read as "nothing to do" when it was in fact invisible from this checkout, and
  story 1030 read the same way until it was marked ready for development. The
  document is where an agent learns to tell them apart before it guesses.

  ## Why the assertions are about words and not about behaviour

  The criterion is about what the document says. A spec cannot judge whether
  prose explains well, so it pins the two conditions being named at all —
  which is the difference between a document that answers this question and one
  that does not mention it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/product.md"

  spex "Why nobody is being offered a story" do
    scenario "an agent consults the document about a story nobody is being offered" do
      given_ "a story that no agent is being offered", context do
        # Not built here on purpose. The criterion is about what the document
        # says, and a story in any particular state would be scenery — the
        # document has to answer whether or not one is in front of you.
        {:ok, context}
      end

      when_ "an agent consults the document", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "it learns a story must be ready for development", context do
        assert context.text =~ ~r/ready for development/i,
               "the document does not name the first condition, so an agent whose story " <>
                 "reports nothing to do has no reason to check it. Got:\n" <>
                 String.slice(context.text, 0, 400)

        {:ok, context}
      end

      then_ "and that it must be assigned to the checkout it is worked on", context do
        assert context.text =~ ~r/assign/i and context.text =~ ~r/working cop|checkout/i,
               "the document does not name the second condition. An agent that knows " <>
                 "only about readiness will mark a story ready, see nothing change, and " <>
                 "have nowhere else to look. Got:\n" <> String.slice(context.text, 0, 400)

        {:ok, context}
      end

      then_ "and that either one missing looks the same from outside", context do
        assert context.text =~ ~r/0\/0|nothing to do|indistinguish|the same/i,
               "the document names both conditions but not the symptom they share, " <>
                 "which is the part that makes the mistake expensive: the reading is " <>
                 "identical, so knowing the conditions is not enough unless you are " <>
                 "told to check both."

        {:ok, context}
      end
    end
  end
end
