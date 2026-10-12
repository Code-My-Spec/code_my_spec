defmodule CodeMySpecSpex.MailboxHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.McpServers.Agents.Tools.WithdrawMessage
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers
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

  @note "SEND-NOW-NOTE-CONTENTS"

  @doc "What the file the agent reads at its tool boundary says."
  def note, do: @note

  @doc """
  The agent mid-turn, its model about to answer with a tool call (story 1051).

  The call reads a file in the copy, so its result is known; `boundary/1` lets
  the model answer with it.
  """
  def mid_turn_before_a_tool_call(ctx) do
    path = Path.join(ctx.request["working_copy"], "note.txt")
    File.write!(path, @note)
    busy(ctx)
    Map.put(ctx, :note_path, path)
  end

  @doc "The model calls its tool; the turn's next request is what follows the result."
  def boundary(ctx) do
    before = length(HeldProvider.seen())
    HeldProvider.release_with_tool_call("read", %{"file_path" => ctx.note_path})
    await(fn -> length(HeldProvider.seen()) > before end)
    ctx
  end

  @doc "What the agent's model was sent in the request after `boundary/1`."
  def after_the_tool_call, do: List.last(HeldProvider.seen())

  @doc "Send through `message_agent`, as main or the operator does."
  def message(ctx, text, opts \\ []) do
    frame = %Frame{assigns: %{current_scope: ctx.scope}}

    {:reply, response, _frame} =
      MessageAgent.execute(
        %{agent_id: ctx.agent.id, message: text, send_now: Keyword.get(opts, :send_now, false)},
        frame
      )

    refute response.isError, inspect(response)
    text_of(response)
  end

  @doc "The message id a queued `message_agent` reply names."
  def message_id(reply) do
    [_, id] = Regex.run(~r/Message id: ([0-9a-f-]{36})/, reply)
    id
  end

  def withdraw(scope, agent_id, id) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} =
      WithdrawMessage.execute(
        %{agent_id: agent_id, message_id: id},
        frame
      )

    response
  end

  defdelegate text_of(response), to: TaskResponseHelpers, as: :response_text

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
