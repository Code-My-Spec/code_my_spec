defmodule CodeMySpec.Analysis.Supervisor do
  @moduledoc """
  Supervision subtree for local analysis execution.

  Boot reconciliation is owned by `CodeMySpec.Analysis.BootRecovery` so it
  also runs on the main server, which serves remote harnesses without running
  analyzers locally.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: CodeMySpec.Analysis.Registry},
      {Task.Supervisor, name: CodeMySpec.Analysis.TaskSupervisor},
      {DynamicSupervisor, name: CodeMySpec.Analysis.ServerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
