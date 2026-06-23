defmodule CodeMySpec.ContentPublishing.ImageAsset do
  @moduledoc """
  Tracks the content hash of each uploaded image per project so a re-sync can
  tell a replaced image (same key, new bytes) from an unchanged one — only
  replacements trigger a Cloudflare purge (story 712, criterion 6273).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project

  @type t :: %__MODULE__{}

  schema "content_images" do
    field :key, :string
    field :content_hash, :string

    belongs_to :project, Project, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(image_asset, attrs) do
    image_asset
    |> cast(attrs, [:key, :content_hash, :project_id])
    |> validate_required([:key, :content_hash, :project_id])
    |> unique_constraint([:project_id, :key])
  end
end
