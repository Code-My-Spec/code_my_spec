defmodule CodeMySpecSpex.Story1065.Criterion3379Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3379 — An agent finds the process without reading the code.

  The rule:

  > The process an agent follows is in the knowledge base, not only in the code
  > that implements it.

  ## The surface is `read_knowledge`, because that is how an agent looks

  An agent does not open files; it calls the tool. So the claim "the knowledge
  base answers it" is a claim about what `read_knowledge` returns, and driving
  anything else here would prove something nobody does.

  ## Why this names a path

  A spec has to ask for something. `process/product.md` is the path this
  criterion adopts — the process family this story's first rules are about,
  under a `process/` area that its siblings (code, qa, devops, sales) will fill
  in beside it. The path is a decision, not an accident: if the implementer
  picks a different one, this is the line that has to change, and changing it
  is how the decision gets recorded rather than drifting.

  ## What it does not assert

  Not that the document is *good*. A spec cannot read for comprehension. What
  it can pin is that the two facts this story was written about — what makes a
  story visible, and that the agent did not have to read the implementation to
  find out — are answerable from the knowledge base. The second half of the
  criterion is the interesting one and is asserted the only way it can be: the
  answer came from the tool, so nothing about it required reading
  `RequirementCalculator` or `StoriesMapper`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/product.md"

  spex "An agent finds the process without reading the code" do
    scenario "an agent that has never done product work here looks it up" do
      given_ "an agent with no prior knowledge of this project's process", context do
        # given: already true — a fresh scope carries no knowledge state to
        # begin with, so "has never done product work here" needs nothing done
        # to it. The only thing that has to exist is the knowledge base, which
        # is committed to the repository under `priv/knowledge/`.
        #
        # Seeding anything here would make the scenario about the seed rather
        # than about what the knowledge base answers.
        {:ok, context}
      end

      when_ "it looks for how a story travels from written down to worked on", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "the knowledge base answers it", context do
        refute context.response.isError,
               "there is nothing at #{@path}, so an agent asking how product work flows " <>
                 "here is told nothing and goes to read the code — which is the whole " <>
                 "complaint this story exists for. Got:\n#{context.text}"

        {:ok, context}
      end

      then_ "and it did not have to read the implementation to find out", context do
        # The second half of the criterion, asserted the only way it can be:
        # the answer arrived from the tool an agent actually calls. Nothing in
        # this scenario opened `RequirementCalculator` or `StoriesMapper`.
        #
        # What the document *says* about visibility belongs to criterion 3380,
        # not here. Asserting it in both would make two criteria one test
        # wearing two names, and the first to be fixed would silently satisfy
        # the second.
        assert context.text != "",
               "the tool answered, but with nothing in it — which reads to an agent " <>
                 "exactly like having no document at all."

        {:ok, context}
      end
    end
  end
end
