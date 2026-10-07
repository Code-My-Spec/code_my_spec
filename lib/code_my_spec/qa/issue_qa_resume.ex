defmodule CodeMySpec.Qa.IssueQaResume do
  @moduledoc "Immutable authorization to resume operationally interrupted issue QA."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "issue_qa_resumes" do
    field(:project_id, :binary_id)
    field(:issue_id, :binary_id)
    field(:attempt_id, :binary_id)
    field(:working_copy_id, :binary_id)
    field(:coding_agent_id, :binary_id)
    field(:coding_task_id, :string)
    field(:authorized_by_agent_id, :binary_id)
    field(:candidate_sha, :string)
    field(:reason, :string)
    field(:authorized_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(resume, attrs) do
    resume
    |> cast(attrs, [
      :project_id,
      :issue_id,
      :attempt_id,
      :working_copy_id,
      :coding_agent_id,
      :coding_task_id,
      :authorized_by_agent_id,
      :candidate_sha,
      :reason,
      :authorized_at
    ])
    |> validate_required([
      :project_id,
      :issue_id,
      :attempt_id,
      :working_copy_id,
      :coding_agent_id,
      :coding_task_id,
      :authorized_by_agent_id,
      :candidate_sha,
      :reason,
      :authorized_at
    ])
    |> validate_format(:candidate_sha, ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/)
    |> validate_length(:reason, min: 1)
    |> unique_constraint(:attempt_id)
  end
end
