defmodule CmsHarness.Project.Supervisor do
  @moduledoc """
  Everything one project needs, and nothing that is not one project's.

  Four children, in this order, `:rest_for_one`:

    1. `ChannelClient` — the connection, and therefore the lease
    2. `Task.Supervisor` — where scans and analyzer runs happen, off the socket
       process
    3. `AnalysisServer` — the analyzer queue, one run at a time
    4. `Watcher` — the filesystem subscription

  `:rest_for_one` because the dependency runs one way. A channel client that
  crashes comes back with a new connection, a new join, and a fresh read model,
  and everything downstream of it is stale at that moment: an in-flight scan is
  computing a manifest against a read model that is being replaced, a queued
  analyzer run belongs to a ledger row the server already closed when the socket
  went, and the watcher holds a debounce timer for a sync that would be sent on
  a connection that no longer exists. Restarting them with it is cheaper and
  more honest than reconciling them.

  It does not run the other way. A watcher crash is a watcher problem; the lease
  should survive it, and under `:rest_for_one` it does.
  """

  use Supervisor

  alias CmsHarness.Project.{AnalysisServer, ChannelClient, Watcher}
  alias CmsHarness.Sync

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    Supervisor.start_link(__MODULE__, project, name: via(project.id))
  end

  def via(project_id), do: {:via, Registry, {CmsHarness.Registry, {:project, project_id}}}

  @impl true
  def init(project) do
    children = [
      {ChannelClient, project: project},
      {Task.Supervisor, name: Sync.task_supervisor(project.id)},
      {AnalysisServer, project: project},
      {Watcher, project: project}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
