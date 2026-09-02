defmodule CodeMySpec.Repo.Migrations.AMachineSaysWhatItsToolsTake do
  use Ecto.Migration

  # `machine_tools` records which tools a machine has; this records what each of
  # them takes. Both, rather than one column of descriptors, because the names
  # are the scoping list — `Agents.machine_tools/3` reads them to decide what an
  # agent may call — and scoping should not depend on documentation being
  # present.
  #
  # Nullable and no default: a harness older than this sends no docs, and null
  # is the honest record of that. `tool_docs` falls back to naming the tool and
  # saying where it is called from, which is what it did for every machine
  # before this column existed.
  def change do
    alter table(:working_copies) do
      add :machine_tool_docs, :map
    end
  end
end
