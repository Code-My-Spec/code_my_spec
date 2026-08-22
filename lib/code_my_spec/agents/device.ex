defmodule CodeMySpec.Agents.Device do
  @moduledoc """
  Where an agent process actually runs, and how the server asks about it.

  The server holds no disk. It cannot start a process on somebody's machine, so
  everything here happens on the device — `CmsHarness.Agents`, reached over the
  harness channel. Same split Provisioning uses for its shell steps: state and
  ordering live server-side, execution happens on the box.

  A behaviour rather than a direct call because the seam is what makes the
  server half testable without a harness, the same way `:fake_providers` makes
  provisioning testable without buying a server.

  ## `list_running/1` is not the same question as the database

  The database says what we asked for. `list_running/1` says what the device
  actually has. Those disagreeing is the entire subject of one criterion — an
  orphaned agent still spending a subscription while nothing tracks it — so
  collapsing them into one source would delete the failure rather than detect
  it.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Users.Scope

  @doc "Starts the agent's process and returns its OS pid."
  @callback start(Agent.t(), String.t()) :: {:ok, pos_integer()} | {:error, term()}

  @doc "Stops one agent's process, and only that one."
  @callback stop(Agent.t()) :: :ok | {:error, term()}

  @doc "The agent ids the device currently has running."
  @callback running_ids(Scope.t()) :: {:ok, [String.t()]} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :agents_device, CodeMySpec.Agents.Device.Fake)

  @spec start(Agent.t(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def start(agent, config_dir), do: impl().start(agent, config_dir)

  @spec stop(Agent.t()) :: :ok | {:error, term()}
  def stop(agent), do: impl().stop(agent)

  @spec running_ids(Scope.t()) :: {:ok, [String.t()]} | {:error, term()}
  def running_ids(scope), do: impl().running_ids(scope)

  @doc """
  A supervision child for the configured device, or nothing.

  The real device is the box at the other end of the harness channel and holds
  no state here. The fake keeps what it was asked to run in a process, so it has
  to be supervised like one — and only where it is actually the device, so a
  production tree never carries a test double.
  """
  @spec child_spec_for_configured() :: Supervisor.child_spec() | module()
  def child_spec_for_configured, do: child_for(impl())

  defp child_for(CodeMySpec.Agents.Device.Fake), do: CodeMySpec.Agents.Device.Fake

  # A supervisor accepts a no-op child rather than a nil, and Task.Supervisor is
  # the cheapest one that is always available.
  defp child_for(_other),
    do: Supervisor.child_spec({Task.Supervisor, name: CodeMySpec.Agents.NoDeviceSupervisor}, id: :agents_no_device)
end
