defmodule CmsHarness.Agents.Tools.ListProblems do
  @moduledoc """
  The first thing a refusal tells an agent to do, carried directly.

  Unlike the others here, this one is not excluded from `run_script` — it was
  reachable, through a script. What made it wrong is the sentence that names it.
  `Validation.Menu` writes the top directive as

      Next: 3 problems in this working copy — call `list_problems`.

  and "call `list_problems`" is an instruction to call a tool. An agent that
  follows it literally gets no such tool, and what it does next is a guess:
  spelling variations, or a script, or the conclusion that the refusal is
  broken. Story 970's QA watched exactly that guessing happen with a different
  name and found spelling variations came first.

  So the menu's directive and the agent's catalog have to agree. Problems are
  the highest-ranked class it has — the reason nothing else gets looked at until
  the tree is clean — so it is the worst one to make an agent hunt for.

  One call per turn, like the rest of the spine.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "list_problems",
    nothing_to: "no problem list it can read"

  @impl true
  def description do
    """
    The problems in this working copy: failing tests, compile errors, and what
    the analyzers found.

    Read this before starting new work when a stop was refused on problems —
    they are ranked above everything else because work built on a broken tree
    fails on the tree rather than on the work.
    """
  end

  @impl true
  def input_schema do
    %{type: "object", properties: %{}, required: []}
  end
end
