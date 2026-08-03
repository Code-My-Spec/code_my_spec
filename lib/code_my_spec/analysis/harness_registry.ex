defmodule CodeMySpec.Analysis.HarnessRegistry do
  @moduledoc """
  Which projects have a light harness able to run analyzers for them, right now.

  A `Registry` keyed by project id, whose values are the channel processes
  themselves. That choice is the point: a harness stops being an executor the
  moment its channel process exits, with nothing to remember to clean up and no
  window in which the server would dispatch work to a machine that has gone.

  Unique keys, because two harnesses holding one project is already refused a
  layer up — the channel is the lease. A second registration failing is
  therefore a bug being caught, not a case to handle.

  Started by `CodeMySpecWeb.Application` rather than by `Analysis.Supervisor`:
  the analysis subtree runs only where analyzers execute locally, and the whole
  point of this table is projects where they do not.
  """

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
