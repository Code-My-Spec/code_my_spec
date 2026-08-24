defmodule CodeMySpecTest.InProcessAgentTransport do
  @moduledoc """
  The machine, without a socket in between.

  Implements `CodeMySpec.Agents.Transport` by calling the harness's own
  `CmsHarness.Agents` and `CmsHarness.Agents.Runner` directly — the same
  functions a real harness runs when the request arrives over its channel. Only
  the transport is removed; the process work is real.

  ## Why this rather than a stub

  A stub answers whatever it was told to answer, and criterion 2828 has shipped
  as a bug three separate times on this project — each covered by tests that
  never involved a process. `Workspaces.Runner.Local` records a pid with no
  supervisor; two `Task.shutdown(:brutal_kill)` sites leave the OS process
  detached; and `reap_if_absent/3` wrote `:stopped` while killing nothing. All
  three passed everything asked of them.

  So a test that wants to know whether an agent stopped spending should be able
  to spawn something real, ask for it to be stopped, and look.

  ## A group that is not there answers `:ok`

  `Runner.stop/2` on a handle whose group does not exist reports `:ok`, because
  nothing of ours is running — which is the honest answer and also what lets a
  test carry an invented `os_pid` without arranging a process for it.
  """

  @behaviour CodeMySpec.Agents.Transport

  alias CmsHarness.Agents
  alias CmsHarness.Agents.Runner

  @impl true
  def start_agent(_working_copy_id, agent, _timeout) do
    case Agents.launch(%{
           "agent_id" => agent.id,
           "engine" => to_string(agent.engine),
           "provider" => agent.provider,
           "config_dir" => agent.config_dir,
           "working_copy" => agent.working_copy,
           "role" => agent.role
         }) do
      {:ok, %{pgid: pgid, boot_id: boot_id}} -> {:ok, %{os_pid: pgid, os_boot_id: boot_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop_agent(_working_copy_id, agent, timeout) do
    Runner.stop(%{pgid: agent.os_pid, boot_id: agent.os_boot_id}, grace_ms: timeout)
  end
end
