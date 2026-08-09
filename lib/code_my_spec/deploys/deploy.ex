defmodule CodeMySpec.Deploys.Deploy do
  @moduledoc """
  One story, on one environment, as it actually went out.

  Replaces `.code_my_spec/devops/deploys/story_<id>.md` — a file the agent
  wrote for itself and the graph then trusted. A row cannot be satisfied by
  writing the word "verified".

  `health_verified_at` is what decides whether a deploy counts. A deploy that
  shipped and never passed its health check is not done, and keeping that in a
  separate column means the field the requirement reads is one only a passing
  check can set.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "deploys" do
    field :environment, :string
    field :commit_sha, :string
    field :version, :string
    field :health_verified_at, :utc_datetime

    belongs_to :project, CodeMySpec.Projects.Project, type: :binary_id
    belongs_to :story, CodeMySpec.Stories.Story

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(deploy, attrs) do
    deploy
    |> cast(attrs, [
      :project_id,
      :story_id,
      :environment,
      :commit_sha,
      :version,
      :health_verified_at
    ])
    |> validate_required([:project_id, :story_id, :environment])
    |> unique_constraint([:story_id, :environment])
  end
end
