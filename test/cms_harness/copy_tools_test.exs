defmodule CmsHarness.CopyToolsTest do
  use ExUnit.Case, async: true

  alias CmsHarness.CopyTools

  setup do
    root = Path.join(System.tmp_dir!(), "copy-tools-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    {physical, 0} = System.cmd("pwd", [], cd: root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: String.trim(physical)}
  end

  test "the agents' read and write act in the named copy and refuse escapes", %{root: root} do
    assert {:ok, _} = run(root, "write", %{"file_path" => "lib/hello.txt", "content" => "hello"})
    assert File.read!(Path.join(root, "lib/hello.txt")) == "hello"
    assert {:ok, text} = run(root, "read", %{"file_path" => "lib/hello.txt"})
    assert text =~ "hello"

    assert {:error, outside} = run(root, "read", %{"file_path" => "../secret"})
    assert outside =~ "outside allowed directories"

    assert :ok = File.ln_s(System.tmp_dir!(), Path.join(root, "escape"))
    assert {:error, _} = run(root, "write", %{"file_path" => "escape/secret", "content" => "x"})
  end

  test "edit is the agents' edit", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "first\nsecond\n")

    assert {:ok, _} =
             run(root, "edit", %{
               "file_path" => "note.txt",
               "old_string" => "second",
               "new_string" => "Main helped"
             })

    assert File.read!(Path.join(root, "note.txt")) == "first\nMain helped\n"
  end

  test "bash runs in the copy and reports its exit code", %{root: root} do
    assert {:ok, text} = run(root, "bash", %{"command" => "pwd; exit 7"})
    assert text =~ "exit code: 7"
    assert text |> String.split("\n") |> hd() == root
  end

  test "a long result spills to Main's file, as an agent's does", %{root: root} do
    assert {:ok, text} = run(root, "bash", %{"command" => "seq 1 5000"})
    assert text =~ "Output too large"
    [_, path] = Regex.run(~r/Full output saved to: (\S+)/, text)
    assert File.read!(path) =~ "4999"
  end

  test "an unknown tool or a call without input is refused by name", %{root: root} do
    assert {:error, message} = run(root, "search", %{"pattern" => "x"})
    assert message =~ "read, write, edit, bash"
    assert {:error, _} = CopyTools.execute(root, %{"tool" => "read"})
  end

  defp run(root, tool, input) do
    CopyTools.execute(root, %{
      "tool" => tool,
      "input" => input,
      "working_copy_id" => Ecto.UUID.generate()
    })
  end
end
