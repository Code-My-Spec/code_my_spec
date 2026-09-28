defmodule CodeMySpec.Repo.Migrations.AnAgentRecordsItsProviderRefusingIt do
  use Ecto.Migration

  # 044599cc: an exhausted provider account left every agent reading as running.
  # Nullable, no defaults: nil means the provider accepted the last turn.
  def change do
    alter table(:agents) do
      add :provider_refusal, :text
      add :provider_refused_at, :utc_datetime_usec
      add :provider_retry_at, :utc_datetime_usec
    end
  end
end
