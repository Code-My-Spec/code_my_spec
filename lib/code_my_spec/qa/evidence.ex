defmodule CodeMySpec.Qa.Evidence do
  @moduledoc """
  Embedded schema for one uploaded evidence file on a QaAttempt.

  `name` is the filename as it sat under the story's screenshot directory;
  `s3_key` is where it landed (`qa/<project_id>/<attempt_id>/<name>`, the
  same prefix-under-owner shape `IssueScreenshotController` already serves
  issue screenshots from); `content_type` and `bytes` come from the file
  itself, not asserted by the caller.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          name: String.t() | nil,
          s3_key: String.t() | nil,
          content_type: String.t() | nil,
          bytes: non_neg_integer() | nil
        }

  @primary_key false
  embedded_schema do
    field :name, :string
    field :s3_key, :string
    field :content_type, :string
    field :bytes, :integer
  end

  @doc "Changeset for one Evidence entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(evidence \\ %__MODULE__{}, attrs) do
    evidence
    |> cast(attrs, [:name, :s3_key, :content_type, :bytes])
    |> validate_required([:name, :s3_key, :content_type, :bytes])
  end
end
