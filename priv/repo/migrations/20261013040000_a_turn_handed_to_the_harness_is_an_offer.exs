defmodule CodeMySpec.Repo.Migrations.ATurnHandedToTheHarnessIsAnOffer do
  use Ecto.Migration

  # The agent row's reservation said "a turn has been handed to the harness and
  # has not started" — the offer recorded beside it already said what was
  # handed. The offer carries the moment now, and the reservation goes.
  def change do
    alter table(:offers) do
      add :turn_requested_at, :utc_datetime_usec
    end

    create index(:offers, [:agent_id, :status, :turn_requested_at])

    alter table(:agents) do
      remove :work_request_id, :string
      remove :work_requested_at, :utc_datetime_usec
    end
  end
end
