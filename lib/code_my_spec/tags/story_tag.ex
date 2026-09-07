defmodule CodeMySpec.Tags.StoryTag do
  @moduledoc """
  Join table connecting tags to stories.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Tags.Tag

  @type t :: %__MODULE__{
          id: integer() | nil,
          tag_id: integer() | nil,
          story_id: integer() | nil,
          tag: Tag.t() | Ecto.Association.NotLoaded.t(),
          story: Story.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "story_tags" do
    belongs_to :tag, Tag
    belongs_to :story, Story

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(story_tag, attrs) do
    story_tag
    |> cast(attrs, [:tag_id, :story_id])
    |> validate_required([:tag_id, :story_id])
    |> foreign_key_constraint(:tag_id)
    |> foreign_key_constraint(:story_id)
    |> unique_constraint([:tag_id, :story_id])
  end
end
