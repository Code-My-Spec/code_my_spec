defmodule CodeMySpec.Agents.Device.Fake do
  @moduledoc """
  A device that starts nothing, for tests and for the server's own suite.

  Holds what it was asked to run in an Agent process keyed by agent id, so
  `running_ids/1` can disagree with the database — which is the point. A fake
  that always answered "yes, running" would make the orphan criterion
  unfailable, and a criterion that cannot fail is not testing anything.

  `forget/1` is how a spec simulates the thing that started an agent going
  away: the process is gone from the device while the row still says running,
  which is exactly the state `Workspaces.Runner.Local` documents against itself.
  """

  @behaviour CodeMySpec.Agents.Device

  use Agent, restart: :temporary

  alias CodeMySpec.Agents.Agent, as: AgentRecord
  alias CodeMySpec.Users.Scope

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl CodeMySpec.Agents.Device
  def start(%AgentRecord{id: id}, _config_dir) do
    os_pid = System.unique_integer([:positive, :monotonic])
    Agent.update(__MODULE__, &Map.put(&1, id, os_pid))
    {:ok, os_pid}
  end

  @impl CodeMySpec.Agents.Device
  def stop(%AgentRecord{id: id}) do
    Agent.update(__MODULE__, &Map.delete(&1, id))
    :ok
  end

  @impl CodeMySpec.Agents.Device
  def running_ids(%Scope{}) do
    {:ok, Agent.get(__MODULE__, &Map.keys/1)}
  end

  @doc """
  Drops an agent from the device without going through `stop/1`.

  The device forgets it; the database does not. That gap is the failure the
  orphan criterion is about, in the one direction a test can arrange.
  """
  @spec forget(String.t()) :: :ok
  def forget(id), do: Agent.update(__MODULE__, &Map.delete(&1, id))

  @doc "Empties the device, for a test that wants to start from nothing."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)
end
