defmodule CodeMySpec.Repo.Migrations.TheCadenceIntervalIsAProjectSetting do
  @moduledoc """
  How often a project's main agent is woken, stored where every other
  per-project setting lives.

  QA of story 1017 found it in `Application.put_env(:code_my_spec,
  :main_agent_cadence, %{project_id => seconds})` — runtime writes to
  application config. Three things wrong with that, in order of how much they
  matter:

  1. It does not survive a restart. An interval somebody deliberately set is
     gone at the next boot, back to the default, silently. A setting that
     reverts without saying so is worse than one that was never offered,
     because the operator believes it is in force.
  2. It is shared mutable state for the whole node — every project's interval in
     one map, mutated in place, outside any supervision or transaction. Two
     projects setting an interval concurrently race on it.
  3. It is unscoped. Every other per-project setting here is a row read through
     `Scope`; this one was readable and writable by any code in the node.

  Nullable and undefaulted here on purpose. The default belongs in the schema,
  the way `subagent_ttl_minutes` and `fix_issues_min_severity` already do it —
  a default in the migration is invisible to anybody reading the struct, and
  the two drift.
  """

  use Ecto.Migration

  def change do
    alter table(:project_configurations) do
      add :main_agent_cadence_seconds, :integer
    end
  end
end
