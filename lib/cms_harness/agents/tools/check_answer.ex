defmodule CmsHarness.Agents.Tools.CheckAnswer do
  @moduledoc "Collect a durable answer by question id. Answers also arrive as queued conversation content; collecting one does not automatically resume its blocked task."

  use CmsHarness.Agents.Tools.Direct,
    name: "check_answer",
    nothing_to: "no way to collect a reply"

  @impl true
  def description do
    """
    Collect the reply to a question you asked with `ask_user_question`.
    `question_id` comes from `list_user_questions`, or from
    the id `ask_user_question` returned when you asked.

    `pending` is an ordinary result, not a failure — the user has not
    answered yet. Do something else useful, or stop; the answer still
    arrives as a message the moment it lands, so this is for recovering one
    you may have missed.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        question_id: %{
          type: "string",
          description: "From `list_user_questions`, or returned by `ask_user_question`."
        }
      },
      required: ["question_id"]
    }
  end
end
