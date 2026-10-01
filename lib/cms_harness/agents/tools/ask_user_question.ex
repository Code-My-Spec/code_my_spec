defmodule CmsHarness.Agents.Tools.AskUserQuestion do
  @moduledoc "Ask a person a structured question or a single free-text question. Creation atomically blocks the linked active task; answers queue as conversation content and require explicit task resumption."

  use CmsHarness.Agents.Tools.Direct,
    name: "ask_user_question",
    nothing_to: "nobody it can ask"

  @impl true
  def description do
    """
    Ask the person a question, offering the answers you want them to choose
    between. Use it the moment you hit a decision only they can make.

    Offer choices when possible; one free-text question may use options: [].
    Omitted task_id links your active task; null asks without linking a task.
    A linked task is blocked, but unrelated work remains available. Collect
    the answer with check_answer and explicitly resume with start_task.
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
        title: %{type: "string", description: "Heading for the notification."},
        task_id: %{
          type: ["string", "null"],
          description: "Task to block. Omit to use your active task; null asks without a task."
        },
        about: %{
          type: "string",
          enum: ["criteria"],
          description:
            "`criteria` when it is about a story's acceptance criteria or spec: it goes " <>
              "to the product agent, which owns them, instead of up to the user."
        }
      },
      required: ["questions"]
    }
  end
end
