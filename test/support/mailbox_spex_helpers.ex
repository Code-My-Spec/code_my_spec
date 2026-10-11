defmodule CodeMySpecSpex.MailboxHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  def start(ctx, role \\ :coding) do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    CmsHarnessTest.Machine.ensure_supervisor()
    root = CodeMySpec.TempFile.dir("mailbox-spex")
    File.mkdir_p!(root)
    agent = Fixtures.running_agent(ctx.scope, working_copy: root, role: role)
    provider = HeldProvider.start()

    request = %{
      "agent_id" => agent.id,
      "working_copy" => root,
      "provider" => "zai",
      "api_key" => "unused",
      "base_url" => provider,
      "role" => to_string(role),
      "on_event" => fn id, event ->
        Agents.record_turn_event(ctx.scope, id, CmsHarnessTest.Machine.encode_turn_event(event))
      end
    }

    assert {:ok, _} = Fixtures.launch_agent(request)
    ExUnit.Callbacks.on_exit(fn -> Fixtures.halt_agent(agent.id) end)
    Map.merge(ctx, %{agent: agent, request: request})
  end

  def busy(ctx) do
    HeldProvider.hold()
    assert {:ok, _} = Agents.send_to_agent(ctx.agent.id, "current turn", :operator_message)
    HeldProvider.await_request()
    ctx
  end

  def entries(ctx), do: Mailbox.entries(ctx.scope, ctx.agent.id)

  def await(fun, attempts \\ 500)
  def await(_fun, 0), do: flunk("mailbox evidence did not reach the expected state")

  def await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end

  def transport(module) do
    prior = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, module)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :agent_transport, prior)
    end)
  end

  defmodule Unconfirmed do
    @moduledoc false
    def dispatch_message(_, _, _, _, _), do: {:error, :message_timed_out}
  end

  defmodule LostAck do
    @moduledoc false
    def dispatch_message(copy, agent, ref, text, timeout) do
      CodeMySpecSpex.Fixtures.dispatch_agent_mail(copy, agent, ref, text, timeout)
      {:error, :message_timed_out}
    end
  end
end
