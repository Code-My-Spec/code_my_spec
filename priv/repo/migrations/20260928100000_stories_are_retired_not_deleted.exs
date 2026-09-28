defmodule CodeMySpec.Repo.Migrations.StoriesAreRetiredNotDeleted do
  @moduledoc """
  A story is retired rather than deleted, so its number is never freed and a
  spec directory or issue naming it never points at a different story.
  """
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :retired_at, :utc_datetime_usec
    end
  end
end
