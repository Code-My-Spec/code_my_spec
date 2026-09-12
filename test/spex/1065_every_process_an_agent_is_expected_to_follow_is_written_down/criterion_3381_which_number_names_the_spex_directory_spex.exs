defmodule CodeMySpecSpex.Story1065.Criterion3381Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3381 — Which number names the spex directory.

  The rule:

  > The document tells a story's id apart from its number, and says what each
  > is for.

  ## Two numbers, both load-bearing, and only one of them names the directory

  Every tool takes the **id**. The spex directory is `test/spex/<number>_<slug>/`
  and `Parser.derive_story_number/1` reads it back to decide whose story a
  failing spec belongs to. They are usually different: story 1031 is number
  1065, and the specs for it — this file included — live under 1065.

  `StoriesMapper` already records what goes wrong when they are confused:
  `test/spex/811_…` derives 811, "a real but unrelated story". So a directory
  named from the id does not fail — it succeeds against the wrong story, which
  is the expensive kind of wrong.

  That knowledge exists today in a comment beside the code that implements it,
  which is the whole shape of this story's complaint.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/product.md"

  spex "Which number names the spex directory" do
    scenario "an agent about to write specs looks up where they belong" do
      given_ "an agent that has a story and is about to write specs for it", context do
        # given: already true — the agent in this scenario is the test, and
        # `process/product.md` is committed to the repository. Nothing reads a
        # story: the criterion is that the document tells an agent holding an
        # id which number names the directory, and building a story whose id
        # and number happened to differ would test the fixture, not the prose.
        {:ok, context}
      end

      when_ "it consults the document for where they belong", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "it learns the directory is named from the story's number", context do
        assert context.text =~ ~r/number/i,
               "the document never mentions a story's number, so an agent has only the " <>
                 "id it was handed and will name the directory from it. Got:\n" <>
                 String.slice(context.text, 0, 400)

        {:ok, context}
      end

      then_ "and that it is not named from the id", context do
        # Both words have to appear, because the criterion is about telling them
        # apart. A document that says "name it from the number" without ever
        # mentioning the id leaves an agent holding an id, reading about a
        # number, and free to assume they are the same thing — which they are
        # for some stories, which is what makes the assumption survive.
        assert context.text =~ ~r/\bid\b/i,
               "the document names the number but never the id, so it never actually " <>
                 "draws the distinction this criterion is about."

        {:ok, context}
      end
    end
  end
end
