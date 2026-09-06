defmodule CmsHarness.Agents.Tools.AskUserQuestion do
  @moduledoc """
  Ask a person a question with the answers already written out.

  Claude Code has this natively and our plugin hook relays it to
  `POST /api/questions/ask` — headers, options with descriptions, single or
  multi select, an "Other" box, delivered as a push. That is the notification
  John has been answering for months.

  Our own agents had no equivalent. `send_message` (then called `ask_user`)
  hardcodes `"options" => []`, which the renderer reads as free-form, so every
  question an Alloy agent asked came back as a paragraph to interpret — however
  closed the question actually was.

  Prefer this over `send_message`. Writing the options is the work: it forces
  the agent to decide what the real alternatives are, and it gives the person a
  tap instead of a paragraph.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "ask_user_question",
    nothing_to: "nobody it can ask"

  @impl true
  def description do
    """
    Ask the person a question, offering the answers you want them to choose
    between. Use it the moment you hit a decision only they can make.

    Prefer this to `send_message` whenever the alternatives can be named —
    deciding what they are is most of the work, and they get a tap rather than
    a paragraph to write. They can always answer "Other" instead.

    You do not wait and you do not poll. Stop after asking; their answer is
    delivered to you as a message.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        questions: %{
          type: "array",
          maxItems: 4,
          description: "One to four questions. More than that is not shown at once.",
          items: %{
            type: "object",
            properties: %{
              question: %{type: "string", description: "The question itself."},
              header: %{
                type: "string",
                description: ~s(A short label, a dozen characters or so, e.g. "Scope".)
              },
              multiSelect: %{
                type: "boolean",
                description: "True if more than one option may be picked. Defaults to false."
              },
              options: %{
                type: "array",
                description:
                  "The choices. Give each a label and, where it is not obvious, " <>
                    "a description of what picking it means.",
                items: %{
                  type: "object",
                  properties: %{
                    label: %{type: "string"},
                    description: %{type: "string"}
                  },
                  required: ["label"]
                }
              }
            },
            required: ["question", "options"]
          }
        },
        title: %{type: "string", description: "Heading for the notification."}
      },
      required: ["questions"]
    }
  end
end
