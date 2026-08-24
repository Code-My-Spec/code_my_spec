defmodule CmsHarnessTest.Machine do
  @moduledoc """
  Drive a real harness from a spex: announce the machine, look at its
  checkouts, start and stop a real process group.

  This is one function in its own module because of where the boundary runs.
  Story 892's criteria are about "the machine looked and told us", so they have
  to drive `CmsHarness.WorkingCopyReporter` itself rather than write
  `path_missing_since` and assert the column can be set. But `CodeMySpecSpex`
  may not reference `CmsHarness` — the dependency runs the other way — and
  calling it from a spex helper compiled a forbidden-reference warning, which
  the analyzer treats as reason to skip exunit, credo and spex entirely. One
  misclassified line holds back every other check.

  `CodeMySpecSpex.Fixtures` is the wrong home for it: that bridge is for
  app-level DB setup that originates server-side, and its deps deliberately
  exclude the harness. `CmsHarnessTest` already exists as the harness-side
  crossing, so the two are symmetric — app state through `Fixtures`, harness
  surfaces through here.
  """
  alias CmsHarness.Agents
  alias CmsHarness.Device
  alias CmsHarness.WorkingCopyReporter

  @doc """
  Report on `reporter`'s checkouts, with `file` as this machine's identity.

  The two arguments travel together on purpose. `CmsHarness.Device` reads the
  identity path out of application env, which is global, so with two harnesses
  in one criterion whichever started last would own the identity and both would
  announce as the same machine — in the criterion about telling two machines
  apart. Setting it here means no caller has to remember the ordering.
  """
  @spec report(pid() | atom(), String.t()) :: %{optional(String.t()) => boolean()}
  def report(reporter, file) do
    Application.put_env(:code_my_spec, :device_config_path, file)
    WorkingCopyReporter.report(reporter)
  end

  @doc """
  A supervisable reporter for `copies`, under a name unique to this criterion.

  The child spec is built here rather than in the spex because naming
  `CmsHarness.WorkingCopyReporter` is itself the crossing — Boundary flags
  cross-boundary *calls*, so a bare module name in a child spec passes the
  check and still puts the harness in a spex's hands.
  """
  @spec reporter(map()) :: {Supervisor.child_spec(), module()}
  def reporter(copies) do
    name = Module.concat(WorkingCopyReporter, "Spex#{System.unique_integer([:positive])}")
    {Supervisor.child_spec({WorkingCopyReporter, name: name, known: copies}, id: name), name}
  end

  @doc """
  Announce this machine, exactly as starting the harness does.

  Story 1020's criterion 2846 is "starting the harness is what onboards the
  machine", so its `when_` has to be this call and not a stand-in for it.
  """
  @spec announce() :: term()
  def announce, do: Device.announce()

  @doc """
  Start a real agent on this machine, under the id the server knows it by.

  Story 1023's criteria are about whether an agent stops *spending*, which a
  thing that does not exist cannot demonstrate — three shipped instances of that
  defect all passed tests with nothing running in them.

  It used to start an OS process group. An agent is a supervised process now, so
  this starts one of those: real, registered, and reachable by the same id the
  server would use. No provider is contacted, because nothing here chats to it.
  """
  @spec start_agent(String.t(), String.t(), (-> any()) | nil) :: {:ok, map()} | {:error, term()}
  def start_agent(agent_id, working_copy, on_stop \\ nil) do
    ensure_supervisor()

    Agents.launch(%{
      "agent_id" => agent_id,
      "provider" => "zai",
      "api_key" => "unused-in-spex",
      "working_copy" => working_copy,
      "on_stop" => on_stop
    })
  end

  @spec stop_agent(String.t()) :: :ok | {:error, :not_running}
  def stop_agent(agent_id) do
    ensure_supervisor()
    Agents.halt(agent_id)
  end

  @doc "Whether this machine is running that agent right now."
  @spec running?(String.t()) :: boolean()
  def running?(agent_id) do
    ensure_supervisor()
    agent_id in Agents.running()
  end

  @doc """
  Make sure the tree an agent lives in exists — both halves of it.

  An agent is supervised by `CmsHarness.AgentSupervisor` and registered in
  `CmsHarness.Registry`, and it needs both: without the registry, starting one
  raises `unknown registry` from inside the `:via` tuple. The harness starts
  both; a spex run starts neither.

  Linked to the caller, so each scenario gets a clean tree and nothing leaks
  into the next.
  """
  @spec ensure_supervisor() :: :ok
  def ensure_supervisor do
    ensure(CmsHarness.Registry, fn ->
      Registry.start_link(keys: :unique, name: CmsHarness.Registry)
    end)

    ensure(CmsHarness.AgentSupervisor, fn ->
      DynamicSupervisor.start_link(name: CmsHarness.AgentSupervisor, strategy: :one_for_one)
    end)
  end

  defp ensure(name, start) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} = start.()
        # Unlinked on purpose: linked, it dies with whichever scenario happened
        # to start it, and the next one either raises `unknown registry` or
        # starts a second tree while agents live in the first.
        Process.unlink(pid)
        :ok

      _pid ->
        :ok
    end
  end
end
