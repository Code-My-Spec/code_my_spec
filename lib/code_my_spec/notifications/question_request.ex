defmodule CodeMySpec.Notifications.QuestionRequest do
  @moduledoc """
  A remote `AskUserQuestion` from Claude Code.

  When the agent asks the user a question, the local hook posts it here and
  blocks; the user answers from their phone (via a Web Push link to
  `QuestionLive.Show`) and the answer is broadcast back to the waiting hook,
  which returns it to the model. Mirrors `PermissionRequest`, but the payload is
  structured questions (with options / multi-select) rather than allow/deny.

  `questions` is the tool's `questions` array verbatim
  (`%{"question", "header", "options" => [%{"label","description"}], "multiSelect"}`);
  `answers` maps each question's text to the chosen label (or list of labels).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `expired` was here with two readers and no writer — nothing in production
  # could ever set it, and only the spex fixtures manufactured it. Story 896
  # decided against building the sweeper that would have made it reachable: a
  # question vanishing on a clock is a decision the user never made
  # disappearing from the one place they would have seen it. Answering is the
  # only terminal state, and in use it is enough (83309b2a).
  @statuses ~w(pending answered)

  schema "question_requests" do
    field :title, :string
    field :questions, {:array, :map}, default: []
    field :status, :string, default: "pending"
    field :answers, :map, default: %{}

    # Claude's session id, so a question can be shown in the conversation it
    # was asked in. Nil when it was asked outside a harness.
    field :session_external_id, :string

    # Which agent asked, so the answer can be handed back to it as a message
    # rather than waited for. Nil when a Claude Code session asked — that path
    # keeps running and polls with `check_answer`.
    belongs_to :agent, CodeMySpec.Agents.Agent, type: :binary_id

    # Where in the transcript it was asked, so it renders beside the work that
    # prompted it rather than pinned above everything. Resolved when the
    # question is created; nil for an asker with no conversation of ours, and
    # for every row written before this existed — those fall to the bottom of
    # the chat, which is right for a pending one and the best available guess
    # for an old answered one.
    belongs_to :conversation_message, CodeMySpec.Conversations.Message, type: :binary_id

    belongs_to :user, CodeMySpec.Users.User, type: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :user_id,
      :agent_id,
      :conversation_message_id,
      :title,
      :questions,
      :status,
      :answers,
      :session_external_id
    ])
    |> validate_required([:user_id])
    |> validate_nonempty_questions()
    |> validate_inclusion(:status, @statuses)
  end

  # `validate_length` skips when the value equals the schema default ([]), so
  # check the field directly to reject a request with no questions.
  defp validate_nonempty_questions(changeset) do
    case get_field(changeset, :questions) do
      [_ | _] -> changeset
      _ -> add_error(changeset, :questions, "must have at least one question")
    end
  end
end
