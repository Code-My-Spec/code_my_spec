defmodule CodeMySpec.Repo.Migrations.AQaAttemptNamesWhatItActuallyUsed do
  use Ecto.Migration

  # 257a6a15: scenarios and prose describe what a QA pass found, never how the
  # evidence was gathered — a passing browser-driven attempt and one that
  # never touched a browser look identical afterward. Nullable, no default:
  # existing attempts predate the field and stay nil rather than being
  # backfilled with a claim nobody made.
  def change do
    alter table(:qa_attempts) do
      add :tools_used, {:array, :string}
    end
  end
end
