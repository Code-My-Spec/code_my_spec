defmodule CodeMySpec.Repo.Migrations.AMachineSaysWhatElseItCanDo do
  @moduledoc """
  Story 982. What a working copy's machine offers beyond the server's own
  tools — a browser, today.

  On the working copy rather than the device, even though it is a property of
  the machine: an agent is started on a copy and its tool list is computed from
  what that copy's harness reported on its last join. Reading it off the device
  would need the copy to resolve one first, and `device_id` is only just
  required — a lookup with a nullable hop in the middle is how "no browser" and
  "no machine recorded" become the same answer.

  Nullable, and the two states are different. `nil` is a harness too old to
  report anything; `{}` is a machine that reported and has no browser. Both
  produce an agent with no browser tools, and only the second is something an
  operator can act on — which is what makes vibium worth being an install
  prerequisite rather than a thing that quietly is not there (issue ebc5586d).
  """

  use Ecto.Migration

  def change do
    alter table(:working_copies) do
      add :machine_tools, {:array, :string}
    end
  end
end
