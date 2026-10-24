defmodule CodeMySpec.AgentAttachmentsTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.AgentAttachments.Transport
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.WorkingCopies

  defmodule FakeTransport do
    @behaviour CodeMySpec.AgentAttachments.Transport
    def request(copy, operation, payload, _timeout) do
      send(self(), {:attachment_request, copy, operation, payload})

      result(Process.get(:attachment_transport_result), operation, payload)
    end

    defp result(nil, "attachment_disconnect", _payload), do: :ok
    defp result(nil, _operation, payload), do: {:ok, %{attachment_id: payload["attachment_id"]}}
    defp result(result, _operation, _payload), do: result
  end

  setup do
    original = Application.get_env(:code_my_spec, :agent_attachment_transport)
    Application.put_env(:code_my_spec, :agent_attachment_transport, FakeTransport)

    on_exit(fn -> restore_transport(original) end)

    scope = full_scope_fixture()
    copy = copy(scope)
    agent = agent(scope, copy)
    %{scope: scope, copy: copy, agent: agent}
  end

  defp restore_transport(nil),
    do: Application.delete_env(:code_my_spec, :agent_attachment_transport)

  defp restore_transport(original),
    do: Application.put_env(:code_my_spec, :agent_attachment_transport, original)

  defp copy(scope) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/attachment-#{copy.id}")
    copy
  end

  defp agent(scope, copy, role \\ :main) do
    Repo.insert!(%Agent{
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      working_copy_id: copy.id,
      working_copy: copy.root,
      role: role,
      provider: "openai",
      status: :running
    })
  end

  test "Main attaches multiple copies without changing its runtime identity", c do
    second = copy(c.scope)
    original = Repo.get!(Agent, c.agent.id)
    assert {:ok, one} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)
    assert {:ok, two} = AgentAttachments.connect(c.scope, c.agent.id, second.id)
    assert {:ok, ^one} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)

    assert MapSet.new(Enum.map(AgentAttachments.list(c.scope, c.agent.id), & &1.id)) ==
             MapSet.new([one.id, two.id])

    assert Repo.get!(Agent, c.agent.id) == original
  end

  test "offline connect persists nothing", c do
    Process.put(:attachment_transport_result, {:error, :harness_unreachable})

    assert {:error, :harness_unreachable} =
             AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)

    assert AgentAttachments.list(c.scope, c.agent.id) == []
  end

  test "transport refuses offline and old harnesses immediately", c do
    assert {:error, :harness_unreachable} =
             Transport.request(c.copy.id, "attachment_connect", %{}, 1)

    assert :ok = HarnessRegistry.register_executor(c.copy.id)

    assert {:error, :attachment_operations_unsupported} =
             Transport.request(c.copy.id, "attachment_connect", %{}, 1)
  end

  test "foreign projects, accounts, non-Main callers and malformed ids are refused", c do
    other = full_scope_fixture()
    foreign = copy(other)
    coding = agent(c.scope, c.copy, :coding)

    assert {:error, :working_copy_not_found} =
             AgentAttachments.connect(c.scope, c.agent.id, foreign.id)

    assert {:error, :unauthorized_agent} = AgentAttachments.connect(other, c.agent.id, foreign.id)
    assert {:error, :unauthorized_agent} = AgentAttachments.connect(c.scope, coding.id, c.copy.id)
    assert {:error, :unauthorized_agent} = AgentAttachments.connect(c.scope, "bad", c.copy.id)

    assert {:error, :working_copy_not_found} =
             AgentAttachments.connect(c.scope, c.agent.id, "bad")

    bad_account = %{c.scope | active_account_id: other.active_account_id}
    assert {:error, :unauthorized_agent} = AgentAttachments.list(bad_account, c.agent.id)
    refute_received {:attachment_request, _, _, _}
  end

  test "disconnect revokes only the selected attachment and reconnect mints a new handle", c do
    second = copy(c.scope)
    coding = agent(c.scope, c.copy, :coding)
    {:ok, one} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)
    {:ok, two} = AgentAttachments.connect(c.scope, c.agent.id, second.id)
    assert :ok = AgentAttachments.disconnect(c.scope, c.agent.id, one.id)
    assert_received {:attachment_request, _, "attachment_disconnect", %{"attachment_id" => id}}
    assert id == one.id
    assert [^two] = AgentAttachments.list(c.scope, c.agent.id)
    assert Repo.get!(Agent, coding.id).status == :running

    assert {:error, :attachment_not_found} =
             AgentAttachments.execute(c.scope, c.agent.id, one.id, "read_file", %{})

    assert {:ok, fresh} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)
    refute fresh.id == one.id
  end

  test "failed remote disconnect still revokes permission without claiming cleanup", c do
    {:ok, one} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)
    Process.put(:attachment_transport_result, {:error, :harness_unreachable})

    assert {:error, :harness_unreachable} =
             AgentAttachments.disconnect(c.scope, c.agent.id, one.id)

    assert AgentAttachments.list(c.scope, c.agent.id) == []
  end

  test "execution preserves explicit target and overrides forged attachment fields", c do
    {:ok, attachment} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)

    assert {:ok, _} =
             AgentAttachments.execute(c.scope, c.agent.id, attachment.id, "read_file", %{
               "path" => "mix.exs",
               "attachment_id" => "forged",
               "operation" => "command"
             })

    assert_received {:attachment_request, copy_id, "attachment_execute", payload}
    assert copy_id == c.copy.id

    assert payload == %{
             "attachment_id" => attachment.id,
             "operation" => "read_file",
             "path" => "mix.exs"
           }

    assert {:error, :unsupported_operation} =
             AgentAttachments.execute(c.scope, c.agent.id, attachment.id, "delete_copy", %{})

    assert {:error, :invalid_id} = AgentAttachments.disconnect(c.scope, c.agent.id, "bad")
  end

  test "another agent cannot use or disconnect Main's attachment", c do
    other = agent(c.scope, c.copy)
    {:ok, attachment} = AgentAttachments.connect(c.scope, c.agent.id, c.copy.id)

    assert {:error, :attachment_not_found} =
             AgentAttachments.disconnect(c.scope, other.id, attachment.id)

    assert {:error, :attachment_not_found} =
             AgentAttachments.execute(c.scope, other.id, attachment.id, "read_file", %{})

    assert [^attachment] = AgentAttachments.list(c.scope, c.agent.id)
  end
end
