defmodule CodeMySpec.Repo.Migrations.ARunRemembersWhoAskedForIt do
  @moduledoc """
  Adds `analysis_runs.requested_by`.

  Nullable, no default: nil means a run enqueued before this column existed,
  or a path nothing has been taught to tag yet — same shape `args`/`stats`
  already use for "we don't have anything structured to say here" rather than
  a sentinel.

  Free-form (`:map`, like `args`/`stats`) instead of a fixed set of columns:
  a hook run carries `session_id`/`agent_id`/`hook`, an MCP tool call carries
  `agent_id` alone, a manual trigger carries neither — the shape varies by
  origin and a rigid schema would need a migration for every new caller this
  gets taught to attribute.
  """

  use Ecto.Migration

  def change do
    alter table(:analysis_runs) do
      add :requested_by, :map
    end
  end
end
