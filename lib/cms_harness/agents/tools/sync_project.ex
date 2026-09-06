defmodule CmsHarness.Agents.Tools.SyncProject do
  @moduledoc """
  The second of the spine, carried directly. See
  `CmsHarness.Agents.Tools.GetNextRequirement` for why all four are here.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "sync_project",
    nothing_to: "nothing to sync it with"

  @impl true
  def description do
    """
    Reconcile the project's files and components with what is on disk, and
    re-embed the knowledge corpus.

    The explicit full pass. `get_next_requirement` syncs files on its own
    without embedding, so reach for this when something about the project's
    shape has changed rather than before every requirement.
    """
  end

  @impl true
  def input_schema do
    %{type: "object", properties: %{}, required: []}
  end
end
