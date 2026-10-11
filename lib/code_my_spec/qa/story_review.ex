defmodule CodeMySpec.Qa.StoryReview do
  @moduledoc "Immutable identity of the certified story and submissions a QA task reviews."
  use Boundary, top_level?: true, deps: [], exports: :all
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "qa_story_reviews" do
    field(:task_id, :string)
    field(:story_id, :integer)
    field(:certified_revision, :string)
    field(:certified_at, :utc_datetime_usec)
    field(:submissions, :map)
    field(:started_at, :utc_datetime_usec)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :task_id,
      :story_id,
      :certified_revision,
      :certified_at,
      :submissions,
      :started_at
    ])
    |> validate_required([
      :task_id,
      :story_id,
      :certified_revision,
      :certified_at,
      :submissions,
      :started_at
    ])
    |> unique_constraint(:task_id)
  end
end
