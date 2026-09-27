defmodule CodeMySpec.Repo.Migrations.ADeclinedOfferCountsItsRepeats do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :declined_offer_count, :integer
    end
  end
end
