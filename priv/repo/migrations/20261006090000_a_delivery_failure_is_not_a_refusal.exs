defmodule CodeMySpec.Repo.Migrations.ADeliveryFailureIsNotARefusal do
  @moduledoc """
  Failed deliveries get their own pacing field.

  `Work.suppress_offer/3` paced retries through the *refusal* streak, and
  `already_declined?/3` reads that streak as "the agent said no". A harness that
  was not up yet therefore looked like a refusal: the work went quiet for the
  decline window and the agent was never offered it again once it was
  reachable. Continuous agents sat idle after restarts for this reason.
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :delivery_failed_offer, :string
      add :delivery_failed_at, :utc_datetime_usec
    end
  end
end
