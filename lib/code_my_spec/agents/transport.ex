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
