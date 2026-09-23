defmodule CodeMySpec.Workspaces.HarnessSource.Installed do
  @moduledoc """
  The published release on PATH — what every real customer's own laptop
  runs, and the only correct answer there: a customer has no `code_my_spec`
  checkout to run from, and should not need one. `cms` is the brew formula's
  own wrapper (`rel/env.sh.eex`'s launcher, symlinked by the tap), on
  whatever cadence that formula ships.
  """

  @behaviour CodeMySpec.Workspaces.HarnessSource

  @impl true
  def command, do: "cms start"
end
