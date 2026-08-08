defmodule CodeMySpec.Repo.Migrations.EnvironmentsTimestampsToMicroseconds do
  use Ecto.Migration

  # `EnvironmentRepository.list/1` orders by `inserted_at` then `name`, and at
  # second precision two environments created in the same second tie — so the
  # tiebreak decides, and `prod` sorts before `uat`.
  #
  # That makes the order environments are provisioned in depend on how fast the
  # run is. Against real providers the two inserts land seconds apart and UAT
  # goes first, which is the story: UAT stands alone, production arrives later.
  # Replayed from a cassette the same two inserts land in one second, `name`
  # breaks the tie, and production is provisioned first.
  #
  # Criterion 8156 failed on exactly this. Its recording holds two server
  # lookups — UAT adopted, production absent and created — and the replay made
  # one, because it started with production and halted. The requests could not
  # line up because the run was not doing the same thing.
  #
  # Microseconds rather than ordering by name, because creation order is the
  # thing being expressed. Ordering by name alone would be deterministic and
  # would also mean production is always provisioned first, which is a
  # behaviour change made to suit a test.
  def change do
    alter table(:provisioning_environments) do
      modify :inserted_at, :utc_datetime_usec, from: :utc_datetime
      modify :updated_at, :utc_datetime_usec, from: :utc_datetime
    end
  end
end
