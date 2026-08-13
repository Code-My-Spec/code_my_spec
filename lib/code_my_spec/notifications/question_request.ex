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

  @statuses ~w(pending answered expired)

  schema "question_requests" do
    field :title, :string
    field :questions, {:array, :map}, default: []
    field :status, :string, default: "pending"
    field :answers, :map, default: %{}

    # Claude's session id, so a question can be shown in the conversation it
    # was asked in. Nil when it was asked outside a harness.
    field :session_external_id, :string

    belongs_to :user, CodeMySpec.Users.User, type: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :title, :questions, :status, :answers, :session_external_id])
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
