defmodule CodeMySpec.AgentAttachmentToolsTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies

  defmodule Transport do
    @behaviour CodeMySpec.AgentAttachments.Transport
    def request(copy, operation, payload, _) do
      send(self(), {:remote, copy, operation, payload})
      respond(Process.get(:attachment_transport_result), operation, payload)
    end

    defp respond(nil, operation, payload), do: result(operation, payload)
    defp respond(override, _operation, _payload), do: override

    defp result("attachment_connect", payload),
      do: {:ok, %{attachment_id: payload["attachment_id"]}}

    defp result("attachment_disconnect", _payload), do: :ok

    defp result("attachment_execute", _payload), do: {:ok, "target output\nexit code: 0"}
  end

  setup do
    original = Application.get_env(:code_my_spec, :agent_attachment_transport)
    Application.put_env(:code_my_spec, :agent_attachment_transport, Transport)

    on_exit(fn -> restore_transport(original) end)

    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/tools-#{copy.id}")
    agent = agent(scope, copy, :main)
    %{scope: scope, copy: copy, agent: agent, context: %{scope: scope, agent_id: agent.id}}
  end

  defp restore_transport(nil),
    do: Application.delete_env(:code_my_spec, :agent_attachment_transport)

  defp restore_transport(original),
    do: Application.put_env(:code_my_spec, :agent_attachment_transport, original)

  defp agent(scope, copy, role) do
    Repo.insert!(%Agent{
      engine: :codex,
      engine_session_id: Ecto.UUID.generate(),
      provider: "openai",
      role: role,
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      working_copy_id: copy.id,
      working_copy: copy.root,
      status: :running
    })
  end

  test "registered tools use injected identity throughout connect, work and disconnect", c do
    assert {:ok, row} =
             ToolLibrary.data("connect_working_copy", %{working_copy_id: c.copy.id}, c.context)

    assert row["agent_id"] == c.agent.id
    assert {:ok, [^row]} = ToolLibrary.data("list_working_copy_attachments", %{}, c.context)

    assert {:ok, "target output\nexit code: 0"} =
             ToolLibrary.run(
               "work_in_copy",
               %{attachment_id: row["id"], tool: "bash", command: "pwd"},
               c.context
             )

    assert_received {:remote, id, "attachment_execute", payload}
    assert id == c.copy.id

    assert payload == %{
             "attachment_id" => row["id"],
             "working_copy_id" => c.copy.id,
             "tool" => "bash",
             "input" => %{"command" => "pwd"}
           }

    assert {:ok, %{"disconnected" => true}} =
             ToolLibrary.data("disconnect_working_copy", %{attachment_id: row["id"]}, c.context)

    assert {:ok, []} = ToolLibrary.data("list_working_copy_attachments", %{}, c.context)
  end

  test "a stale remote session surfaces a reconnect hint rather than a bare atom", c do
    assert {:ok, row} =
             ToolLibrary.data("connect_working_copy", %{working_copy_id: c.copy.id}, c.context)

    Process.put(:attachment_transport_result, {:error, :attachment_not_connected})

    assert {:error, message} =
             ToolLibrary.run(
               "work_in_copy",
               %{attachment_id: row["id"], tool: "read", file_path: "identity.txt"},
               c.context
             )

    assert message =~ "connect_working_copy"
    assert message =~ "idempotent"
  end

  test "trusted terminal context resolves Main without model-supplied identity", c do
    context = %{scope: c.scope, session_id: c.agent.engine_session_id}

    assert {:ok, row} =
             ToolLibrary.data("connect_working_copy", %{working_copy_id: c.copy.id}, context)

    assert row["agent_id"] == c.agent.id
  end

  test "model-supplied session identity cannot impersonate Main", c do
    assert {:error, :agent_required} =
             ToolLibrary.data(
               "connect_working_copy",
               %{
                 working_copy_id: c.copy.id,
                 session_id: c.agent.engine_session_id
               },
               %{scope: c.scope}
             )

    assert AgentAttachments.list(c.scope, c.agent.id) == []
    refute_received {:remote, _, _, _}
  end

  test "injected Coding or QA identity cannot be upgraded by Main session parameters", c do
    for role <- [:coding, :qa, :product] do
      caller = agent(c.scope, c.copy, role)

      assert {:error, :unauthorized_agent} =
               ToolLibrary.data(
                 "connect_working_copy",
                 %{
                   working_copy_id: c.copy.id,
                   session_id: c.agent.engine_session_id
                 },
                 %{scope: c.scope, agent_id: caller.id}
               )
    end

    refute_received {:remote, _, _, _}
  end

  test "all tools reject missing caller and project scope", c do
    calls = [
      {"connect_working_copy", %{working_copy_id: c.copy.id}},
      {"disconnect_working_copy", %{attachment_id: Ecto.UUID.generate()}},
      {"list_working_copy_attachments", %{}},
      {"work_in_copy", %{attachment_id: Ecto.UUID.generate(), tool: "read"}}
    ]

    for {name, params} <- calls do
      assert {:error, :agent_required} = ToolLibrary.data(name, params, %{scope: c.scope})

      assert {:error, :missing_active_project} =
               ToolLibrary.data(name, params, %{agent_id: c.agent.id})
    end
  end

  test "malformed arguments fail through validation without remote work", c do
    calls = [
      {"connect_working_copy", %{}},
      {"connect_working_copy", %{working_copy_id: 42}},
      {"disconnect_working_copy", %{attachment_id: []}},
      {"work_in_copy", %{attachment_id: Ecto.UUID.generate(), tool: "delete_working_copy"}},
      {"work_in_copy", %{attachment_id: Ecto.UUID.generate(), tool: "bash", timeout: "soon"}},
      {"work_in_copy", %{attachment_id: Ecto.UUID.generate(), tool: "write", content: %{}}}
    ]

    for {name, params} <- calls do
      assert {:error, _} = ToolLibrary.data(name, params, c.context)
    end

    refute_received {:remote, _, _, _}
  end
end
