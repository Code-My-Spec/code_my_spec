defmodule CodeMySpec.CopyToolsTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies

  defmodule Transport do
    @behaviour CodeMySpec.CopyTools.Transport
    def request(copy, operation, payload, timeout) do
      send(self(), {:remote, copy, operation, payload, timeout})
      Process.get(:copy_transport_result) || {:ok, "target output\nexit code: 0"}
    end
  end

  setup do
    original = Application.get_env(:code_my_spec, :copy_tools_transport)
    Application.put_env(:code_my_spec, :copy_tools_transport, Transport)

    on_exit(fn -> restore(original) end)

    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/copy-tools-#{copy.id}")
    main = agent(scope, :main)
    %{scope: scope, copy: copy, main: main, context: %{scope: scope, agent_id: main.id}}
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :copy_tools_transport)
  defp restore(original), do: Application.put_env(:code_my_spec, :copy_tools_transport, original)

  defp agent(scope, role) do
    Repo.insert!(%Agent{
      engine: :codex,
      engine_session_id: Ecto.UUID.generate(),
      provider: "openai",
      role: role,
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      working_copy: "/tmp/agent-#{role}",
      status: :running
    })
  end

  test "Main's bash names its copy and reaches that copy's harness with the tool's own input",
       c do
    assert {:ok, "target output\nexit code: 0"} =
             ToolLibrary.run("bash", %{working_copy_id: c.copy.id, command: "pwd"}, c.context)

    assert_received {:remote, id, "copy_tool", payload, timeout}
    assert id == c.copy.id
    assert timeout > :timer.hours(1)

    assert payload == %{
             "working_copy_id" => c.copy.id,
             "tool" => "bash",
             "input" => %{"command" => "pwd"}
           }
  end

  test "read, write and edit carry their own inputs", c do
    for {tool, input} <- [
          {"read", %{file_path: "mix.exs", limit: 5}},
          {"write", %{file_path: "a.txt", content: "x"}},
          {"edit", %{file_path: "a.txt", old_string: "x", new_string: "y", replace_all: true}}
        ] do
      assert {:ok, _} =
               ToolLibrary.run(tool, Map.put(input, :working_copy_id, c.copy.id), c.context)

      assert_received {:remote, _, "copy_tool", %{"tool" => ^tool, "input" => sent}, _}
      assert sent == Map.new(input, fn {k, v} -> {to_string(k), v} end)
    end
  end

  test "only Main reaches another copy; Coding, QA, retired and off Mains are refused", c do
    for role <- [:coding, :qa, :product] do
      other = agent(c.scope, role)

      assert {:error, message} =
               ToolLibrary.run(
                 "read",
                 %{working_copy_id: c.copy.id, file_path: "mix.exs"},
                 %{c.context | agent_id: other.id}
               )

      assert message =~ "Only Main"
    end

    c.main |> Ecto.Changeset.change(retired_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :main_only} =
             ToolLibrary.data("read", %{working_copy_id: c.copy.id, file_path: "x"}, c.context)

    refute_received {:remote, _, _, _, _}
  end

  test "a copy in another project, or no copy at all, is refused before anything is sent", c do
    other = full_scope_fixture()
    {:ok, foreign} = WorkingCopies.issue(other, nil, device: device_fixture(other))
    {:ok, foreign} = WorkingCopies.report_root(foreign, "/tmp/foreign-#{foreign.id}")

    for id <- [foreign.id, Ecto.UUID.generate(), "not-an-id"] do
      assert {:error, :working_copy_not_found} =
               ToolLibrary.data("read", %{working_copy_id: id, file_path: "x"}, c.context)
    end

    refute_received {:remote, _, _, _, _}
  end

  test "an offline copy is a plain error, and a missing id fails validation", c do
    Process.put(:copy_transport_result, {:error, :harness_unreachable})

    assert {:error, message} =
             ToolLibrary.run("bash", %{working_copy_id: c.copy.id, command: "ls"}, c.context)

    assert message =~ "not connected"
    assert {:error, _} = ToolLibrary.data("bash", %{command: "ls"}, c.context)
  end
end
