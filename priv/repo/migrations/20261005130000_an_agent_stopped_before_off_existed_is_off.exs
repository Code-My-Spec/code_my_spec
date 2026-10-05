defmodule CodeMySpec.Repo.Migrations.AnAgentStoppedBeforeOffExistedIsOff do
  use Ecto.Migration

  # Phase 2 (v2.0.372) reads on duty as `off_at` and `retired_at` both nil, and
  # `status` no longer decides it. An agent stopped before `off_at` existed
  # (2026-09-28) has neither, so it read as on duty and every harness join
  # restored it: about 190 old agents came up on 2026-10-05.
  #
  # Those stops were turn-offs: `stopped_reason` nil (before 2026-09-23) or
  # `stopped`. A `reaped` agent went away while on duty and is still owed its
  # restore, so it is left alone. Not reversible: afterwards a legacy stop
  # cannot be told from a turn-off.
  def up do
    execute("""
    UPDATE agents
    SET off_at = updated_at, off_reason = 'stopped before an agent could be turned off'
    WHERE status = 'stopped'
      AND off_at IS NULL
      AND retired_at IS NULL
      AND (stopped_reason IS NULL OR stopped_reason = 'stopped')
    """)
  end

  def down, do: :ok
end
