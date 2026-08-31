defmodule CodeMySpec.Repo.Migrations.AMachineSaysWhyItHasNoBrowser do
  @moduledoc """
  Issue 02b03d04. `machine_tools` already has three states — null for a harness
  that never reported, `[]` for one that reported nothing, and a list — but the
  middle one covers two different machines: one with no browser, and one whose
  browser is installed and could not be reached.

  A QA agent on the second is recorded with its tools, none of which can look at
  a page, and the only trace was a warning in the harness log. It does not fail;
  it never looks.

  Nullable and without a default, deliberately: null means "has not said", which
  is the same thing null means in `machine_tools` beside it, and every row that
  exists now genuinely has not said.
  """

  use Ecto.Migration

  def change do
    alter table(:working_copies) do
      # "ready" | "absent" | "unreachable". A string rather than a native enum,
      # on purpose — see issue 42b32a6e, where `file_role` being a Postgres enum
      # cost a dedicated migration and a redeploy for each new value.
      add :browser_status, :string
      add :browser_error, :text
    end
  end
end
