defmodule CmsHarness.AttachmentsTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Attachments

  setup do
    ensure_process(
      Process.whereis(CmsHarness.Registry),
      {Registry, keys: :unique, name: CmsHarness.Registry}
    )

    ensure_process(
      Process.whereis(CmsHarness.AttachmentsSupervisor),
      {DynamicSupervisor, name: CmsHarness.AttachmentsSupervisor, strategy: :one_for_one}
    )

    root = Path.join(System.tmp_dir!(), "attachment-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    id = Ecto.UUID.generate()
    assert {:ok, _} = Attachments.request(root, "attachment_connect", %{"attachment_id" => id})

    on_exit(fn ->
      Attachments.request(root, "attachment_disconnect", %{"attachment_id" => id})
      File.rm_rf!(root)
    end)

    %{root: root, id: id}
  end

  test "the agents' read and write target the attachment root and refuse escapes", %{
    root: root,
    id: id
  } do
    assert {:ok, _} =
             execute(root, id, "write", %{"file_path" => "lib/hello.txt", "content" => "hello"})

    assert File.read!(Path.join(root, "lib/hello.txt")) == "hello"
    assert {:ok, text} = execute(root, id, "read", %{"file_path" => "lib/hello.txt"})
    assert text =~ "hello"

    assert {:error, outside} = execute(root, id, "read", %{"file_path" => "../secret"})
    assert outside =~ "outside allowed directories"

    assert :ok = File.ln_s(System.tmp_dir!(), Path.join(root, "escape"))

    assert {:error, _} =
             execute(root, id, "write", %{"file_path" => "escape/secret", "content" => "bad"})

    refute File.exists?(Path.join(System.tmp_dir!(), "secret"))

    other = Path.join(root, "other")

    assert {:error, :attachment_not_connected} =
             execute(other, id, "read", %{"file_path" => "lib/hello.txt"})
  end

  test "edit is the agents' edit, in the attached copy", %{root: root, id: id} do
    File.write!(Path.join(root, "note.txt"), "first\nsecond\n")

    assert {:ok, _} =
             execute(root, id, "edit", %{
               "file_path" => "note.txt",
               "old_string" => "second",
               "new_string" => "Main helped"
             })

    assert File.read!(Path.join(root, "note.txt")) == "first\nMain helped\n"
  end

  test "bash runs in the selected copy and reports its exit code", %{root: root, id: id} do
    assert {:ok, text} = execute(root, id, "bash", %{"command" => "pwd; exit 7"})
    assert text =~ "exit code: 7"
    [pwd | _] = String.split(text, "\n")
    assert pwd in [root, "/private" <> root]
  end

  test "a long result spills to the attachment's own file, as an agent's does", %{
    root: root,
    id: id
  } do
    assert {:ok, text} = execute(root, id, "bash", %{"command" => "seq 1 5000"})
    assert text =~ "Output too large"
    [_, path] = Regex.run(~r/Full output saved to: (\S+)/, text)
    assert path =~ "attachment-#{id}"
    assert File.read!(path) =~ "4999"
  end

  test "an unknown tool is refused by name", %{root: root, id: id} do
    assert {:error, message} = execute(root, id, "search", %{"pattern" => "x"})
    assert message =~ "read, write, edit, bash"
  end

  test "disconnect kills its subprocess and leaves an independent attachment usable", %{
    root: root,
    id: id
  } do
    other_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Attachments.request(root, "attachment_connect", %{"attachment_id" => other_id})

    on_exit(fn ->
      Attachments.request(root, "attachment_disconnect", %{"attachment_id" => other_id})
    end)

    pid_file = Path.join(root, "running.pid")

    task =
      Task.async(fn ->
        execute(root, id, "bash", %{
          "command" => "sh -c 'echo $$ > running.pid; exec sleep 60'",
          "timeout" => 60_000
        })
      end)

    assert wait_for_file(pid_file, 100)
    os_pid = File.read!(pid_file) |> String.trim()
    assert :ok = Attachments.request(root, "attachment_disconnect", %{"attachment_id" => id})
    assert {:error, :attachment_disconnected} = Task.await(task)
    assert {_output, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    assert status != 0

    assert {:error, :attachment_not_connected} =
             execute(root, id, "read", %{"file_path" => "running.pid"})

    assert {:ok, _} = execute(root, other_id, "read", %{"file_path" => "running.pid"})
  end

  test "concurrent disconnects remain idempotent as the session exits", %{root: root, id: id} do
    disconnect = fn ->
      Attachments.request(root, "attachment_disconnect", %{"attachment_id" => id})
    end

    tasks = for _ <- 1..20, do: Task.async(disconnect)
    assert Enum.all?(tasks, &(Task.await(&1) == :ok))
    assert :ok = disconnect.()

    assert {:error, :attachment_not_connected} =
             execute(root, id, "read", %{"file_path" => "anything"})
  end

  defp execute(root, id, tool, input) do
    Attachments.request(root, "attachment_execute", %{
      "attachment_id" => id,
      "tool" => tool,
      "input" => input
    })
  end

  defp wait_for_file(_path, 0), do: false

  defp wait_for_file(path, count), do: wait_for_contents(File.read(path), path, count)

  defp wait_for_contents({:ok, bytes}, _path, _count) when byte_size(bytes) > 0, do: true

  defp wait_for_contents(_result, path, count) do
    Process.sleep(20)
    wait_for_file(path, count - 1)
  end

  defp ensure_process(nil, child), do: start_supervised!(child)
  defp ensure_process(pid, _child), do: pid
end
