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

  test "file operations target the attachment root and refuse path escapes", %{root: root, id: id} do
    assert :ok =
             execute(root, id, %{
               "operation" => "write_file",
               "path" => "lib/hello.txt",
               "content" => "hello"
             })

    assert {:ok, "hello"} =
             execute(root, id, %{"operation" => "read_file", "path" => "lib/hello.txt"})

    assert {:error, :path_outside_working_copy} =
             execute(root, id, %{"operation" => "read_file", "path" => "../secret"})

    assert :ok = File.ln_s(System.tmp_dir!(), Path.join(root, "escape"))

    assert {:error, :symlink_path_not_allowed} =
             execute(root, id, %{
               "operation" => "write_file",
               "path" => "escape/secret",
               "content" => "bad"
             })

    other = Path.join(root, "other")

    assert {:error, :attachment_not_connected} =
             execute(other, id, %{"operation" => "read_file", "path" => "lib/hello.txt"})
  end

  test "search returns bounded literal matches and ignores symbolic links", %{root: root, id: id} do
    File.write!(Path.join(root, "note.txt"), "first\nmatch [x]\n")

    assert {:ok, [%{path: "note.txt", line: 2, text: "match [x]"}]} =
             execute(root, id, %{"operation" => "search", "pattern" => "[x]"})
  end

  test "command returns output and exit status from the selected copy", %{root: root, id: id} do
    assert {:ok, %{output: output, exit_status: 7}} =
             execute(root, id, %{
               "operation" => "command",
               "command" => "sh",
               "args" => ["-c", "pwd; exit 7"]
             })

    assert String.trim(output) == root or String.trim(output) == "/private" <> root
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
        execute(root, id, %{
          "operation" => "command",
          "command" => "sh",
          "args" => ["-c", "echo $$ > running.pid; exec sleep 60"]
        })
      end)

    assert wait_for_file(pid_file, 100)
    os_pid = File.read!(pid_file) |> String.trim()
    assert :ok = Attachments.request(root, "attachment_disconnect", %{"attachment_id" => id})
    assert {:error, :attachment_disconnected} = Task.await(task)
    assert {_output, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    assert status != 0

    assert {:error, :attachment_not_connected} =
             execute(root, id, %{"operation" => "list_directory"})

    assert {:ok, _} = execute(root, other_id, %{"operation" => "list_directory"})
  end

  test "disconnect kills a background child after command has returned", %{root: root, id: id} do
    assert {:ok, %{exit_status: 0}} =
             execute(root, id, %{
               "operation" => "command",
               "command" => "sh",
               "args" => ["-c", "sleep 60 & echo $! > background.pid"]
             })

    os_pid = root |> Path.join("background.pid") |> File.read!() |> String.trim()
    assert {_output, 0} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    assert :ok = Attachments.request(root, "attachment_disconnect", %{"attachment_id" => id})
    assert {_output, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    assert status != 0
  end

  defp execute(root, id, payload),
    do: Attachments.request(root, "attachment_execute", Map.put(payload, "attachment_id", id))

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
