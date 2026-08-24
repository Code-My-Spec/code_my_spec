defmodule CodeMySpec.Agents.Transport do
  @moduledoc """
  Reaching the machine an agent's process is on, behind a seam.

  The server owns the record and the machine owns the process. Stopping an agent
  is therefore a request to somebody else's computer, and the answer decides
  whether it was a stop at all — `Agents.stop_agent/2` records `:stopped` only
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
  Give a running agent something to do, and wait for the turn.

  The capability the whole engine change was for. Delivering a message used to
  mean a held stdin pipe — a FIFO with a writer inside the agent's own process
  group so it never saw EOF, plus a protocol nobody had written down. It is a
  call now, and this is the seam it crosses.

  Answers `{:ok, text}` with whatever the agent said, or `{:error, reason}`. A
  turn can take minutes: the timeout is the caller's choice rather than a
  constant here, because "send a one-line instruction" and "work on this story"
  are the same call with very different patience.
  """
  @callback message_agent(
              working_copy_id :: String.t(),
              agent :: Agent.t(),
              message :: String.t(),
              timeout()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Hand a running agent a message without waiting for the turn.

  The same delivery as `message_agent/4` and a different promise. That one is
  for a caller who wants the answer and can wait minutes for it; this is for a
  person at a page, who cannot. What the agent says comes back the way
  everything else it does comes back — as turn events, in the transcript they
  are already reading.

  Answers `{:ok, :started}` or `{:ok, :queued}`. The difference is the only
  thing the sender can still act on: a queued message can be taken back, and a
  started one is already the agent's.
  """
  @callback dispatch_message(
              working_copy_id :: String.t(),
              agent :: Agent.t(),
              ref :: String.t(),
              message :: String.t(),
              timeout()
            ) :: {:ok, :started | :queued} | {:error, term()}

  @doc """
  Take back a message the agent has not picked up yet.

  `{:error, :already_delivered}` is a real answer rather than a failure: the
  turn ended while the operator was reaching for the control. Reporting success
  there would leave them believing the agent was stopped while it acts on the
  thing they thought they took back.
  """
  @callback withdraw_message(
              working_copy_id :: String.t(),
              agent :: Agent.t(),
              ref :: String.t(),
              timeout()
            ) :: :ok | {:error, term()}

  @doc """
  Ask the machine serving `working_copy_id` to end this agent's process group.

  `:ok` means the group is gone and the caller may record the stop.
  `{:error, reason}` means it is not, and the caller must not.
  """
  @callback stop_agent(working_copy_id :: String.t(), agent :: Agent.t(), timeout()) ::
              :ok | {:error, term()}

  @doc "The configured transport. Defaults to the real channel."
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :agent_transport, __MODULE__.Harness)
end
