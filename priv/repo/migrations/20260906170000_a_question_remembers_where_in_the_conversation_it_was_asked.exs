defmodule CodeMySpec.Repo.Migrations.AQuestionRemembersWhereInTheConversationItWasAsked do
  @moduledoc """
  Where in the transcript the question belongs.

  The conversation page already renders questions — the same
  `ChatComponents.question/1` the standalone page uses, form and all — but in a
  block pinned above the transcript. So the question floats at the top,
  detached from the turn that produced it, which is the thing its own handler
  argues against: "a question read without the work that prompted it is a
  question you cannot answer well."

  Position by timestamp was the obvious alternative and it is not reliable:
  `question_requests.inserted_at` is second-resolution while
  `conversation_messages.inserted_at` carries microseconds, so a question and
  the turn that asked it land in the same second and sort either way. Rendering
  a question *before* the turn that asked it is the exact failure the pinned
  block already has.

  So it is anchored rather than sorted. Resolved at ask time, which is why no
  MCP plumbing is needed: the tool does not have to know its own tool-call id,
  it only has to know which conversation it is in.

  Nullable, and the null is ordinary rather than a gap: a question from a Claude
  Code session has no conversation of ours to sit in, which is the whole reason
  `QuestionLive.Show` exists. Those render there, as they always have.

  `nilify_all` for the same reason as `agent_id`: the question and its answer
  are the person's record and outlive whichever turn happened to raise them.
  """

  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :conversation_message_id,
          references(:conversation_messages, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:question_requests, [:conversation_message_id])
  end
end
