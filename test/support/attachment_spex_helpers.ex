defmodule CodeMySpecSpex.AttachmentHelpers do
  @moduledoc """
  Story 1149: Main's read, write, edit and bash, each naming a working
  copy (issue e377de11), over an in-process transport simulation with isolated
  roots. This is not two-host evidence. Only network delivery is substituted;
  CmsHarness.CopyTools runs the agents' own tools exactly as on a device.
  """
  import ExUnit.Assertions
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  defmodule Transport do
    @moduledoc false
    def request(copy, _event, payload, _timeout) do
      {root, mode} = Agent.get(__MODULE__, &Map.fetch!(&1, copy))

      case mode do
        :offline ->
          {:error, :harness_unreachable}

        :online ->
          CmsHarnessTest.AttachmentRuntime.request(root, payload)

        :drop ->
          spawn(fn -> CmsHarnessTest.AttachmentRuntime.request(root, payload) end)
          CodeMySpecSpex.AttachmentHelpers.await_file(Path.join(root, "started"))
          {:error, :connection_lost}
      end
    end
  end

  def setup(context) do
    ExUnit.Callbacks.start_supervised!(%{
      id: Transport,
      start: {Agent, :start_link, [fn -> %{} end, [name: Transport]]}
    })

    previous = Application.get_env(:code_my_spec, :copy_tools_transport)
    Application.put_env(:code_my_spec, :copy_tools_transport, Transport)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:code_my_spec, :copy_tools_transport, previous),
        else: Application.delete_env(:code_my_spec, :copy_tools_transport)
    end)

    scope = %{context.scope | active_working_copy_id: nil}
    main = Fixtures.running_agent(scope, role: "main", execution_mode: :detached)
    Fixtures.agent_said(scope, main, "Remember our original project conversation")
    c = Map.merge(context, %{main: main, tool_context: %{scope: scope, agent_id: main.id}})
    one = copy(scope, "laptop")
    two = copy(scope, "remote")

    workers =
      Enum.map(["coding", "qa"], fn role ->
        Fixtures.running_agent(%{scope | active_working_copy_id: one.id},
          role: role,
          working_copy: one.root
        )
      end)

    Map.merge(c, %{
      one: one,
      two: two,
      workers: workers,
      original_agents: data(c, "list_agents"),
      original_conversation: conversation(c)
    })
  end

  def copy(scope, name) do
    root = CodeMySpec.TempFile.owned_dir("attachment-spex-#{name}")
    {physical_root, 0} = System.cmd("pwd", [], cd: root)
    root = String.trim(physical_root)
    File.write!(Path.join(root, "identity.txt"), name)
    device = Fixtures.device_fixture(scope, %{hostname: name})
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device)
    {:ok, copy} = WorkingCopies.report_root(copy, root)
    Agent.update(Transport, &Map.put(&1, copy.id, {root, :online}))
    copy
  end

  def data(c, name, args \\ %{}) do
    assert {:ok, value} = ToolLibrary.data(name, args, c.tool_context)
    value
  end

  def result(c, name, args), do: ToolLibrary.data(name, args, c.tool_context)

  # Main's own tools, naming the copy they run in.
  def work(c, copy, tool, input \\ %{}),
    do: data(c, tool, Map.put(input, :working_copy_id, copy.id))

  def read(c, copy, path), do: work(c, copy, "read", %{file_path: path})

  # Bash's result: the command's output, then `exit code: N`.
  def bash(c, copy, command) do
    text = work(c, copy, "bash", %{command: command})
    [_, output, status] = Regex.run(~r/\A(.*)\nexit code: (\d+)\z/s, text)
    %{output: output, exit_status: String.to_integer(status)}
  end

  def mode(copy, mode), do: Agent.update(Transport, &Map.put(&1, copy.id, {copy.root, mode}))

  def conversation(c) do
    assert {:ok, body} =
             ToolLibrary.run("read_agent_conversation", %{agent_id: c.main.id}, c.tool_context)

    body
  end

  def unchanged(c) do
    assert data(c, "list_agents") == c.original_agents
    assert conversation(c) == c.original_conversation
    assert conversation(c) =~ "Remember our original project conversation"
  end

  def await_file(path, tries \\ 200)
  def await_file(_path, 0), do: flunk("remote command never reached its observable checkpoint")

  def await_file(path, tries) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_file(path, tries - 1)
        )
  end

  def exercise(c, criterion) when criterion in [2403, 2411] do
    target = if criterion == 2403, do: c.one, else: c.two
    other = if criterion == 2403, do: c.two, else: c.one
    identity = if criterion == 2403, do: "laptop", else: "remote"
    other_identity = if criterion == 2403, do: "remote", else: "laptop"
    assert read(c, target, "identity.txt") =~ identity
    assert bash(c, target, "grep -rl #{identity} .").output =~ "identity.txt"
    assert bash(c, target, "ls").output =~ "identity.txt"
    work(c, target, "write", %{file_path: "identity.txt", content: "Main helped"})
    assert read(c, target, "identity.txt") =~ "Main helped"

    work(c, target, "edit", %{
      file_path: "identity.txt",
      old_string: "Main helped",
      new_string: "Main edited"
    })

    assert read(c, target, "identity.txt") =~ "Main edited"
    result = bash(c, target, "pwd")
    assert String.trim(result.output) == target.root
    assert result.exit_status == 0
    assert read(c, other, "identity.txt") =~ other_identity
    unchanged(c)
  end

  def exercise(c, 2414) do
    assert read(c, c.one, "identity.txt") =~ "laptop"
  end

  # Only Main reaches another copy this way; its coder's identity is refused.
  def exercise(c, 2415) do
    [coder | _] = c.workers

    assert {:error, :main_only} =
             ToolLibrary.data(
               "write",
               %{working_copy_id: c.one.id, file_path: "identity.txt", content: "unauthorized"},
               %{c.tool_context | agent_id: coder.id}
             )

    assert read(c, c.one, "identity.txt") =~ "laptop"
  end

  def exercise(c, 2416) do
    result = bash(c, c.two, "pwd")
    assert String.trim(result.output) == c.two.root
    assert result.exit_status == 0
  end

  # Offline is a hard error on the call; back online, the next call just works.
  def exercise(c, 2417) do
    mode(c.two, :offline)

    assert {:error, :harness_unreachable} =
             result(c, "write", %{
               working_copy_id: c.two.id,
               file_path: "identity.txt",
               content: "wrong destination"
             })

    mode(c.two, :online)
    assert read(c, c.two, "identity.txt") =~ "remote"
    assert read(c, c.one, "identity.txt") =~ "laptop"
    unchanged(c)
  end

  def exercise(c, 2423) do
    mode(c.two, :drop)

    assert {:error, :connection_lost} =
             result(c, "bash", %{
               working_copy_id: c.two.id,
               command:
                 "sh -c 'echo once >> executions; touch started; sleep 0.1; touch finished'"
             })

    await_file(Path.join(c.two.root, "finished"))
    mode(c.two, :online)
    assert length(Regex.scan(~r/once/, read(c, c.two, "executions"))) == 1
    unchanged(c)
  end
end

defmodule CmsHarnessTest.AttachmentRuntime do
  @moduledoc "Harness-side bridge for copy-tool Spex, using the real runtime."
  def request(root, payload), do: CmsHarness.CopyTools.execute(root, payload)
end
