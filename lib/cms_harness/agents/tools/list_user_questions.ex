defmodule CmsHarness.Agents.Tools.ListUserQuestions do
  @moduledoc """
  Every question this agent has asked the user in this session, oldest first.

  The other half of `ask_user_question` / `send_message`. Both of those tell
  the agent to stop and wait for the answer to arrive as a message, and
  `Validation.Menu`'s own offer names this and `check_answer` as how to find
  a reply once one lands: "`list_user_questions` shows them, `check_answer`
  collects a reply once it lands." That sentence went out on every refusal
  and neither tool was carried — the same gap `send_message`'s own moduledoc
  describes for `ask_user`: a capability added at the spine and not to the
  Alloy agents reads, from the outside, as a model refusing an instruction.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "list_user_questions",
    nothing_to: "no questions it could have asked"

  @impl true
  def description do
    """
    Everything you are waiting on the user for, in this session, oldest
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
