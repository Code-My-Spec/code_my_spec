defmodule CodeMySpecSpex.AttachmentHelpers do
  @moduledoc """
  Stories 1148/1149: real tool/domain/runtime execution over an in-process
  transport simulation with isolated roots. This is not two-host evidence.
  Only network delivery is substituted; CmsHarness.Attachments executes files
  and subprocesses and owns cancellation exactly as it does on a device.
  """
  import ExUnit.Assertions
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  defmodule Transport do
    def request(copy, event, payload, _timeout) do
      {root, mode} = Agent.get(__MODULE__, &Map.fetch!(&1, copy))

      case mode do
        :offline ->
          {:error, :harness_unreachable}

        :online ->
          CmsHarnessTest.AttachmentRuntime.request(root, event, payload)

        :drop ->
          spawn(fn -> CmsHarnessTest.AttachmentRuntime.request(root, event, payload) end)
          CodeMySpecSpex.AttachmentHelpers.await_file(Path.join(root, "started"))
          {:error, :connection_lost}
      end
    end
  end

  def setup(context) do
    CmsHarnessTest.AttachmentRuntime.start()

    ExUnit.Callbacks.start_supervised!(%{
      id: Transport,
      start: {Agent, :start_link, [fn -> %{} end, [name: Transport]]}
    })

    previous = Application.get_env(:code_my_spec, :agent_attachment_transport)
    Application.put_env(:code_my_spec, :agent_attachment_transport, Transport)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:code_my_spec, :agent_attachment_transport, previous),
        else: Application.delete_env(:code_my_spec, :agent_attachment_transport)
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

  def connect(c, copy) do
    attachment = data(c, "connect_working_copy", %{working_copy_id: copy.id})

    ExUnit.Callbacks.on_exit(fn ->
      CmsHarnessTest.AttachmentRuntime.request(copy.root, "attachment_disconnect", %{
        "attachment_id" => attachment["id"]
      })
    end)

    attachment
  end

  def attachments(c), do: data(c, "list_working_copy_attachments")

  def work(c, a, op, args \\ %{}),
    do: data(c, "work_in_copy", Map.merge(args, %{attachment_id: a["id"], operation: op}))

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

  def exercise(c, 2410) do
    rows = data(c, "list_working_copies")

    for copy <- [c.one, c.two] do
      row = Enum.find(rows, &(&1["id"] == copy.id))
      assert row["device_id"] == copy.device_id
      assert row["device_name"] in ["laptop", "remote"]
    end
  end

  def exercise(c, criterion) when criterion in [2412, 2418] do
    one = connect(c, c.one)
    two = connect(c, c.two)
    assert one["id"] != two["id"]
    assert MapSet.new(attachments(c)) == MapSet.new([one, two])
    unchanged(c)
  end

  def exercise(c, criterion) when criterion in [2413, 2420] do
    attachment = connect(c, c.one)
    assert attachment["working_copy_id"] == c.one.id
    assert attachment["agent_id"] == c.main.id
    assert attachments(c) == [attachment]
    unchanged(c)
  end

  def exercise(c, 2421) do
    foreign = copy(Fixtures.full_scope_fixture(), "foreign")
    assert {:error, _} = result(c, "connect_working_copy", %{working_copy_id: foreign.id})
    assert attachments(c) == []
    unchanged(c)
  end

  def exercise(c, 2422) do
    mode(c.one, :offline)

    assert {:error, :harness_unreachable} =
             result(c, "connect_working_copy", %{working_copy_id: c.one.id})

    assert attachments(c) == []
    mode(c.one, :online)
    assert attachments(c) == []
  end

  def exercise(c, 2419) do
    one = connect(c, c.one)
    two = connect(c, c.two)

    task =
      Task.async(fn ->
        result(c, "work_in_copy", %{
          attachment_id: one["id"],
          operation: "command",
          command: "sh",
          args: ["-c", "touch started; sleep 30; touch survived"]
        })
      end)

    await_file(Path.join(c.one.root, "started"))
    assert data(c, "disconnect_working_copy", %{attachment_id: one["id"]})["disconnected"]
    assert {:error, _} = Task.await(task, 5_000)
    assert attachments(c) == [two]
    assert work(c, two, "read_file", %{path: "identity.txt"}) == "remote"

    assert {:error, _} =
             result(c, "work_in_copy", %{
               attachment_id: one["id"],
               operation: "read_file",
               path: "identity.txt"
             })

    assert Enum.any?(data(c, "list_working_copies"), &(&1["id"] == c.one.id))
    unchanged(c)
  end

  def exercise(c, criterion) when criterion in [2403, 2411] do
    target = if criterion == 2403, do: c.one, else: c.two
    other = if criterion == 2403, do: c.two, else: c.one
    identity = if criterion == 2403, do: "laptop", else: "remote"
    other_identity = if criterion == 2403, do: "remote", else: "laptop"
    a = connect(c, target)
    assert work(c, a, "read_file", %{path: "identity.txt"}) == identity
    assert inspect(work(c, a, "search", %{pattern: identity})) =~ "identity.txt"
    assert inspect(work(c, a, "list_directory")) =~ "identity.txt"
    work(c, a, "write_file", %{path: "identity.txt", content: "Main helped"})
    assert work(c, a, "read_file", %{path: "identity.txt"}) == "Main helped"
    result = work(c, a, "command", %{command: "pwd", args: []})
    assert String.trim(result.output) == target.root
    assert result.exit_status == 0
    one = connect(c, other)
    assert work(c, one, "read_file", %{path: "identity.txt"}) == other_identity
    unchanged(c)
  end

  def exercise(c, 2414) do
    a = connect(c, c.one)
    assert work(c, a, "read_file", %{path: "identity.txt"}) == "laptop"
  end

  def exercise(c, 2415) do
    assert {:error, _} =
             result(c, "work_in_copy", %{
               attachment_id: c.one.id,
               operation: "write_file",
               path: "identity.txt",
               content: "unauthorized"
             })

    a = connect(c, c.one)
    assert work(c, a, "read_file", %{path: "identity.txt"}) == "laptop"
  end

  def exercise(c, 2416) do
    a = connect(c, c.two)
    result = work(c, a, "command", %{command: "pwd", args: []})
    assert String.trim(result.output) == c.two.root
    assert result.exit_status == 0
  end

  def exercise(c, 2417) do
    a = connect(c, c.two)
    mode(c.two, :offline)

    assert {:error, :harness_unreachable} =
             result(c, "work_in_copy", %{
               attachment_id: a["id"],
               operation: "write_file",
               path: "identity.txt",
               content: "wrong destination"
             })

    # The real transport's attachment session dies with the OS-level
    # connection, so coming back online needs an explicit reconnect -- a
    # bare work_in_copy on the original handle is not the recovery path
    # (issue 46cbb416). connect_working_copy is idempotent: same copy id
    # back gives the same attachment id, never a second one.
    mode(c.two, :online)
    reconnected = data(c, "connect_working_copy", %{working_copy_id: c.two.id})
    assert reconnected["id"] == a["id"]
    assert work(c, reconnected, "read_file", %{path: "identity.txt"}) == "remote"
    one = connect(c, c.one)
    assert work(c, one, "read_file", %{path: "identity.txt"}) == "laptop"
    unchanged(c)
  end

  def exercise(c, 2423) do
    a = connect(c, c.two)
    mode(c.two, :drop)

    assert {:error, :connection_lost} =
             result(c, "work_in_copy", %{
               attachment_id: a["id"],
               operation: "command",
               command: "sh",
               args: ["-c", "echo once >> executions; touch started; sleep 0.1; touch finished"]
             })

    await_file(Path.join(c.two.root, "finished"))
    mode(c.two, :online)
    assert work(c, a, "read_file", %{path: "executions"}) == "once\n"
    unchanged(c)
  end
end

defmodule CmsHarnessTest.AttachmentRuntime do
  @moduledoc "Harness-side bridge for attachment Spex, using the real runtime."
  def request(root, event, payload), do: CmsHarness.Attachments.request(root, event, payload)

  def start do
    CmsHarnessTest.Machine.ensure_supervisor()

    unless Process.whereis(CmsHarness.AttachmentsSupervisor) do
      ExUnit.Callbacks.start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: CmsHarness.AttachmentsSupervisor}
      )
    end
  end
end
