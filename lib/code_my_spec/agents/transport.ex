defmodule CodeMySpec.Agents.Transport do
  @moduledoc """
  Reaching the machine an agent's process is on, behind a seam.

  The server owns the record and the machine owns the process. Stopping an agent
  is therefore a request to somebody else's computer, and the answer decides
  whether it was a stop at all — `Agents.turn_off_agent/3` records `:stopped` only
  once this says the group is gone.

  ## Why synchronous

  Rule 2 of story 961: a stop is not reported done until something confirms the
  process is gone. A fire-and-forget push cannot honour that — it would return
  success the instant the message left, which is exactly the shape the old
  implementation had when it wrote `status: :stopped` and killed nothing.

  So this blocks on the far side's answer, the same way
  `Analysis.harness_fs_request/4` does for a read that has to happen where the
  disk is. The channel process parks the caller against a ref and answers out of
  band, so waiting here does not block the harness's channel.

  ## Why a seam

  The same reason `CmsHarness.Device.Client` has one. The far side is a socket
  to another machine, and a test that cannot swap it either needs a real harness
  or asserts nothing. Read at call time so a test can swap it per case.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox

  @doc """
  Ask the machine serving `working_copy_id` to launch this agent.

  Answers `{:ok, %{os_pid: group_id, os_boot_id: boot}}` — the pair
  `Agents.record_started/3` writes together, because a group id without its boot
  cannot later be told from a recycled number.

  What to run is decided on the far side. The server knows the engine, the
  config directory and the working copy; the machine knows what is installed on
  it, and a machine with no `pi` on its PATH is a fact only that machine has. It
  says so rather than the server assuming.
  """
  @callback start_agent(working_copy_id :: String.t(), agent :: Agent.t(), timeout()) ::
              {:ok, %{os_pid: pos_integer(), os_boot_id: String.t()}} | {:error, term()}

  @doc """
  Hand a running agent a message without waiting for the turn.

  Execution requires the database mailbox to acknowledge consumption.
  Replies arrive as turn events in the conversation.

  Answers `{:ok, :started}` only after consumption. A busy engine refuses the
  dispatch; waiting work stays in the database mailbox.
  """
  @callback dispatch_message(
              working_copy_id :: String.t(),
              agent :: Agent.t(),
              ref :: String.t(),
              message :: String.t(),
              timeout()
            ) :: {:ok, :started} | {:error, term()}

  @doc "Request work on an existing idle Engine; never queue it as user chat."
  @callback request_work_turn(String.t(), Agent.t(), String.t(), String.t(), timeout()) ::
              {:ok, :started} | {:error, term()}

  @doc """
  Call a tool that lives on the machine rather than here.

  A browser is an MCP server on somebody's box, so a script calling one has to
  come back down. The hop is cheap — a channel round trip on localhost — and
  what it replaces is a model turn, which is not.

  Answers the tool's text, or why it could not be reached. `{:error,
  :harness_unreachable}` when nothing holds that copy, which is a different
  thing from a tool that ran and failed and gets a different sentence in front
  of the agent.
  """
  @callback call_machine_tool(
              working_copy_id :: String.t(),
              tool :: String.t(),
              arguments :: map(),
              timeout()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Ask the machine serving `working_copy_id` to end this agent's process group.

  `:ok` means the group is gone and the caller may record the stop.
  `{:error, reason}` means it is not, and the caller must not.
  """
  @callback stop_agent(working_copy_id :: String.t(), agent :: Agent.t(), timeout()) ::
              :ok | {:error, term()}

  @doc """
  Ask the machine running this agent to stop its current turn, so a message
  sent now is its next one (story 1051). Fire and forget: `:ok` means the ask
  went out; the turn ending is reported as any turn's end is.
  """
  @callback interrupt_turn(working_copy_id :: String.t(), agent :: Agent.t()) ::
              :ok | {:error, term()}

  # Optional: a transport with no running turns to stop answers
  # `{:error, :unsupported}` through `interrupt_turn/2` below.
  @optional_callbacks interrupt_turn: 2

  @doc """
  Make a checkout on a machine that is running a harness.

  The one callback here that does not name a checkout, because it asks for one
  to exist. The address is a machine instead, and any connected copy of the
  project stands for the machine it is on — its harness holds the repository, so
  it can make a sibling worktree beside it.

  `{:error, :no_harness}` when nothing is connected. That is a refusal, not a
  wait: a request for a checkout that cannot be satisfied is refused, and no row
  is written for a directory nobody made.
  """
  @callback create_working_copy(
              candidate_working_copy_ids :: [String.t()],
              request :: map(),
              timeout()
            ) :: {:ok, %{root: String.t(), working_copy_id: String.t()}} | {:error, term()}

  @doc "The configured transport. Defaults to the real channel."
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :agent_transport, __MODULE__.Harness)

  # The gate (39af5611). Everything that reaches an agent's process — a launch,
  # a message, a dispatch, a work turn — goes through these four, and an agent
  # that is off or retired gets `{:error, {:off | :retired, agent}}` instead.
  # Read fresh, not off the caller's struct, so a turn-off lands on queued work.

  @doc "`:ok` if this agent may be delivered to, else why not. The gate, asked ahead."
  @spec deliverable(Agent.t()) :: :ok | {:error, {:off | :retired, Agent.t()}}
  def deliverable(%Agent{id: id}) do
    case AgentsRepository.get_stood_down(id) do
      nil -> :ok
      %Agent{retired_at: %DateTime{}} = retired -> {:error, {:retired, retired}}
      off -> {:error, {:off, off}}
    end
  end

  @doc "Stop the agent's running turn for a message sent now (story 1051)."
  def interrupt_turn(copy_id, %Agent{} = agent) do
    if function_exported?(implementation(agent), :interrupt_turn, 2),
      do: implementation(agent).interrupt_turn(copy_id, agent),
      else: {:error, :unsupported}
  end

  @doc "Launch, unless the agent is off or retired."
  def start_agent(copy_id, %Agent{} = agent, timeout),
    do: gated(agent, fn -> implementation(agent).start_agent(copy_id, agent, timeout) end)

  @doc "Dispatch a message, unless the agent is off or retired."
  def dispatch_message(copy_id, %Agent{} = agent, ref, text, timeout),
    do:
      gated(agent, fn ->
        implementation(agent).dispatch_message(copy_id, agent, ref, text, timeout)
      end)

  @doc "Offer a work turn, unless the agent is off or retired."
  def request_work_turn(copy_id, %Agent{} = agent, ref, text, timeout) do
    if Mailbox.pending?(agent.id),
      do: {:error, :busy},
      else:
        gated(agent, fn ->
          implementation(agent).request_work_turn(copy_id, agent, ref, text, timeout)
        end)
  end

  @doc "Stop on the execution host that owns this agent."
  def stop_agent(copy_id, %Agent{} = agent, timeout),
    do: implementation(agent).stop_agent(copy_id, agent, timeout)

  defp implementation(%Agent{execution_mode: :detached, role: :product}) do
    if Application.get_env(:code_my_spec, :env) == :desktop,
      do: Application.fetch_env!(:code_my_spec, :desktop_agent_transport),
      else: impl()
  end

  defp implementation(_agent), do: impl()

  defp gated(agent, deliver) do
    with :ok <- deliverable(agent), do: deliver.()
  end
end
