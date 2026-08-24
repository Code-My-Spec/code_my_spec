defmodule CodeMySpec.Repo.Migrations.AnAgentRecordsWhichBootItsGroupBelongsTo do
  use Ecto.Migration

  @moduledoc """
  `os_pid` alone cannot say whether the process it names is still ours.

  The agent's `os_pid` is now a process *group* id, so one signal takes the
  agent and everything it spawned. Group ids are reused, so a number recorded
  before a reboot can name an unrelated process afterwards — and signalling that
  is the worst failure available here, because it kills a stranger's process and
  nothing would trace it back.

  So the boot the number belongs to is recorded with it, and liveness is "same
  boot **and** the group exists".

  ## Why it lives on the row rather than in the harness

  The harness could keep it in memory, and that works right up to the case the
  reaping exists for. A harness restart is routine (`just refresh-harness`), the
  agent survives it deliberately, and the harness afterwards has to decide
  whether a group id the *server* handed it is safe to signal. In-memory state
  is gone by then.

  Nullable, because an agent that was never confirmed by a device has neither a
  group id nor a boot to record — `record_started/3` is what sets both, together.
  """

  def change do
    alter table(:agents) do
      add :os_boot_id, :string
    end
  end
end
