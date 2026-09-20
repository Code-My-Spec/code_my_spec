defmodule CmsHarness.Agents.Tools.ListUserQuestions do
  @moduledoc "List the durable agent's open questions in ask order, including their task links. Unanswered questions block only their linked tasks, not unrelated work."

  use CmsHarness.Agents.Tools.Direct,
    name: "list_user_questions",
    nothing_to: "no questions it could have asked"

  @impl true
  def description do
    """
    Everything this durable agent is waiting on the user for, oldest
    first — answered questions are not included.

    Use it to recover what you asked before a compaction, or to check
    whether a question you raised earlier is still open before asking
    another. Call `check_answer` with an id from here to collect a reply
    once it lands.
    """
  end

  @impl true
  def input_schema do
    %{type: "object", properties: %{}, required: []}
  end
end
