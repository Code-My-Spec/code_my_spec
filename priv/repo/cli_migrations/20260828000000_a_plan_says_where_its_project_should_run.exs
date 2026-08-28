defmodule CodeMySpec.Repo.Migrations.APlanSaysWhereItsProjectShouldRun do
  use Ecto.Migration

  @moduledoc """
  Story 875. Both paths out of intake end in a working copy — one on the
  visitor's own machine, one on a box we run — and which they get is their
  choice rather than ours.

  Nullable, and it stays that way. A plan that has not reached the confirmation
  card has not been asked yet, and "not asked" is a real state that must stay
  distinguishable from either answer. Defaulting it here would make every plan
  look like it had chosen, including the ones abandoned before the question.
  """

  def change do
    alter table(:intake_plans) do
      add :location, :string
    end
  end
end
