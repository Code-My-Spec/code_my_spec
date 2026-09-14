defmodule CmsHarness.Agents.Tools.CheckAnswer do
  @moduledoc """
  Fetch the reply to a question raised by `ask_user_question` or
  `send_message`.

  The collecting half of a deliberately two-step exchange: asking stops the
  agent rather than holding it open to poll, and the reply is dispatched back
  as a message when it lands — but a question raised before a restart or a
  compaction has to be collected by id, which is what this is for.

  Carried for the same reason `list_user_questions` is: `Validation.Menu`'s
  offer names both on every refusal ("`list_user_questions` shows them,
  `check_answer` collects a reply once one lands"), and until now neither was
  in `Engine.tools/1` — a sentence naming tools the agent did not have.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "check_answer",
    nothing_to: "no way to collect a reply"

  @impl true
  def description do
    """
    Collect the reply to a question you asked with `ask_user_question` or
    `send_message`. `question_id` comes from `list_user_questions`, or from
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
