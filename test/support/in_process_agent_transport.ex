defmodule CodeMySpecTest.InProcessAgentTransport do
  @moduledoc """
  The server talking to the machine without a socket in between.

  Every step is the real one except the wire: `CodeMySpec.Agents` asks a
  transport, this transport is `CmsHarness.Agents`, and that starts a real
  supervised agent. What is removed is the channel, and only the channel.

  That matters more than it sounds for this story's criteria. They are about
  whether stopping an agent stops the thing that spends money, and a double
  that returned `:ok` without a process would assert nothing — which is exactly
  how three shipped instances of that defect passed everything asked of them.
  """

  @behaviour CodeMySpec.Agents.Transport

  alias CmsHarness.Agents
  alias CmsHarness.WorkingCopies.Create
  alias CmsHarnessTest.Machine
  alias CodeMySpec.Agents.LaunchRequest

  @impl true
  def start_agent(_working_copy_id, agent, _timeout) do
    Machine.ensure_supervisor()

    # The same map the channel would carry, built the same way. Assembling a
    # second one here is what made this double agree with itself and with
    # nothing else — a field added to the wire reached the socket and not the
    # suite, so a criterion driving this proved nothing about production.
    #
    # A key is put on top for providers that need one: nothing here chats to
    # the agent, so none is ever spent, and a provider that needs a key and
    # does not get one is a different failure with its own criterion.
    request =
      agent
      |> LaunchRequest.for()
      |> Map.put_new("api_key", "unused-in-process")

    Agents.launch(request)
  end

  @impl true
  def stop_agent(_working_copy_id, agent, _timeout) do
    Machine.ensure_supervisor()
    Agents.halt(agent.id)
  end

  @impl true
  def message_agent(_working_copy_id, agent, message, timeout) do
    Machine.ensure_supervisor()
    Agents.message(agent.id, message, timeout)
  end

  @impl true
  def dispatch_message(_working_copy_id, agent, ref, message, timeout) do
    Machine.ensure_supervisor()
    Agents.send_message(agent.id, ref, message, timeout)
  end

  @impl true
  def withdraw_message(_working_copy_id, agent, ref, _timeout) do
    Machine.ensure_supervisor()
    Agents.withdraw(agent.id, ref)
  end

  # The real `Create`, against a real repository, without the wire — the same
  # bargain the rest of this module strikes. A double that answered with a path
  # and made no directory would assert nothing, and criteria about a copy being
  # onboarded, staffed and reachable would all pass over an empty answer.
  #
  # The repository is made here because in-process there is no harness holding
  # one. That is the only thing standing in for production: `git worktree add`
  # is really run, `.cms_harness.json` is really written, and what comes back is
  # a directory that exists.
  @impl true
  def create_working_copy([], _request, _timeout), do: {:error, :no_harness}

  def create_working_copy(_candidate_ids, request, _timeout) do
    Create.run(host_repository(), request)
  end

  # One repository per test process, cleaned up with it.
  defp host_repository do
    case Process.get(__MODULE__) do
      nil ->
        root = temp_dir("host_repository")

        {_, 0} =
          System.cmd("git", ["init", "--initial-branch=main", root], stderr_to_stdout: true)

        File.write!(Path.join(root, "README.md"), "host\n")
        {_, 0} = System.cmd("git", ["add", "."], cd: root, stderr_to_stdout: true)

        {_, 0} =
          System.cmd(
            "git",
            ["-c", "user.email=spex@example.com", "-c", "user.name=Spex", "commit", "-m", "root"],
            cd: root,
            stderr_to_stdout: true
          )

        Process.put(__MODULE__, root)
        root

      root ->
        root
    end
  end

  @impl true
  def call_machine_tool(_working_copy_id, tool, arguments, timeout) do
    # In this VM the browser is whatever the local MCP transport was told to
    # offer, so the round trip is the part that is stood in for and the answer
    # is the one a criterion asserts on.
    #
    # The deadline is passed on because the real transport passes it on, and a
    # stand-in that dropped it would make the one hop this seam stands for the
    # one hop nothing proves. Nothing in this VM waits for it.
    CodeMySpecTest.InVmMcpTransport.call(
      {CodeMySpecTest.InVmMcpTransport, :browser},
      tool,
      arguments,
      timeout: timeout
    )
  end

  # A temp directory, without `Briefly`.
  #
  # `Briefly.Entry.ensure_tmp/0` asks one GenServer for the calling process's
  # temp root with a hardcoded 5-second `GenServer.call` and no option to raise
  # it, so on a box running several suites at once it times out and the test
  # exits — `** (exit) exited in: GenServer.call(_, {:monitor, _}, 5000)`,
  # recorded as a failure and blocking every promotion until somebody re-ran the
  # suite while the machine was quiet. `TempFile.dir/1` touches no process.
  #
  # Cleanup is ours now rather than Briefly's process-exit hook. Registered at
  # the point the directory is made, and `on_exit` is LIFO, so it runs after
  # anything the caller registers afterwards.
  defp temp_dir(prefix) do
    dir = CodeMySpec.TempFile.dir(prefix)
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
