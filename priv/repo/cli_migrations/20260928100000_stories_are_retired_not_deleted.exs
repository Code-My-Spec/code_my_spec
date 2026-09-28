defmodule CodeMySpec.Repo.Migrations.StoriesAreRetiredNotDeleted do
  @moduledoc """
  The SQLite counterpart of the Postgres `stories_are_retired_not_deleted`.
  """
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :retired_at, :utc_datetime_usec
    end
  end
end
