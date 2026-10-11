defmodule CodeMySpec.Repo.Migrations.DropAgentDeliveryFailurePacing do
  @moduledoc """
  The delivery-retry timer is gone: an undeliverable turn is recorded as an
  undelivered offer, so these pacing fields have no reader or writer.
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      remove :delivery_failed_offer, :string
      remove :delivery_failed_at, :utc_datetime_usec
    end
  end
end
