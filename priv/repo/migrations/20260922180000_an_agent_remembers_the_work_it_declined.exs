defmodule CodeMySpec.Repo.Migrations.AnAgentRemembersTheWorkItDeclined do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :declined_offer, :string
      add :declined_offer_at, :utc_datetime_usec
    end
  end
end
