defmodule CodeMySpec.Agents.Mailbox.WireTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  alias CmsHarness.Project.ChannelClient
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.MailboxWire.Channel, as: Wire
  alias CodeMySpecTest.MailboxWire.Transport, as: WireTransport
  alias Ecto.Adapters.SQL.Sandbox

  test "engine startup and delivery can call back through the channel without deadlocking" do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    CmsHarnessTest.Machine.ensure_supervisor()
    scope = full_scope_fixture()
    root = CodeMySpec.TempFile.dir("mailbox-wire")
    File.mkdir_p!(root)
    agent = Fixtures.running_agent(scope, working_copy: root)
    wire = start_supervised!({Wire, {root, scope}})
    provider = HeldProvider.start()
    CodeMySpecTest.AgentTransportRouter.route(scope, WireTransport)
    on_exit(fn -> CmsHarness.Agents.halt(agent.id) end)

    assert %{"status" => "ok"} =
             GenServer.call(
               wire,
               {:launch,
                %{
                  "agent_id" => agent.id,
                  "working_copy" => root,
                  "provider" => "zai",
                  "api_key" => "unused",
                  "base_url" => provider,
                  "on_event" => fn id, event ->
                    Agents.record_turn_event(scope, id, ChannelClient.encode_turn_event(event))
                  end
                }},
               5_000
             )

    HeldProvider.hold()

    assert {:ok, :started} =
             Agents.send_to_agent(agent.id, "one actual execution", :operator_message)

    HeldProvider.await_request()
    assert [%{state: :consumed, generation: generation}] = Mailbox.entries(scope, agent.id)
    assert is_binary(generation)
    assert {:ok, :queued} = Agents.send_to_agent(agent.id, "waiting in DB", :operator_message)
    assert {:ok, %{busy?: true}} = CmsHarness.Agents.status(agent.id)
    assert [%{state: :consumed}, %{state: :queued}] = Mailbox.entries(scope, agent.id)
    HeldProvider.release()
  end
end
