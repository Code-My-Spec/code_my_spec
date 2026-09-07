defmodule CodeMySpec.Chat.RunnerLiveTest do
  @moduledoc """
  The live conversation path — the one a browser takes.

  `run_live/1` used to be a stub that failed every send with "no model
  configured for this conversation", so the feature only ever worked under
  `mix spex`, where `:chat_llm` replaces the whole path with a script. QA
  found nine of story 995's thirteen criteria unexercisable against the
  running app (issue `1d82eeea`) — everything the spex proved was about a
  path production never takes.

  These tests fake only the network, through `Chat.Provider`. The loop under
  test is the real one: history assembly, tool-call decoding, executing the
  call, feeding the result back, the round cap, and error handling.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Chat.Runner
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias ReqLLM.Message.ContentPart

  # --- fake providers -------------------------------------------------------

  defmodule Replies do
    @moduledoc false
    use Agent

    def start(replies), do: Agent.start_link(fn -> replies end, name: __MODULE__)

    def next do
      Agent.get_and_update(__MODULE__, fn
        [] -> {{:error, "ran out of scripted replies"}, []}
        [reply | rest] -> {reply, rest}
      end)
    end

    def seen, do: Agent.get(__MODULE__, & &1)
  end

  defmodule ScriptedProvider do
    @moduledoc false
    @behaviour CodeMySpec.Chat.Provider

    @impl true
    def ready?, do: true

    @impl true
    def generate_text(_model, messages, opts) do
      send(self(), {:provider_called, messages, opts})
      Replies.next()
    end
  end

  defmodule UnreadyProvider do
    @moduledoc false
    @behaviour CodeMySpec.Chat.Provider

    @impl true
    def ready?, do: false

    @impl true
    def generate_text(_model, _messages, _opts), do: {:error, :should_not_be_called}
  end

  # --- helpers --------------------------------------------------------------

  # `ReqLLM.Response` enforces :id, :model and :context; they play no part in
  # what the runner reads, so they are filled with the least interesting values
  # that satisfy the struct.
  defp response(message) do
    {:ok,
     %ReqLLM.Response{
       id: "resp_test",
       model: "test:model",
       context: %ReqLLM.Context{messages: []},
       message: message
     }}
  end

  defp text_reply(text) do
    response(%ReqLLM.Message{
      role: :assistant,
      content: [ContentPart.text(text)]
    })
  end

  defp tool_reply(name, args, text \\ "") do
    response(%ReqLLM.Message{
      role: :assistant,
      content: [ContentPart.text(text)],
      tool_calls: [ReqLLM.ToolCall.new("call_live_1", name, Jason.encode!(args))]
    })
  end

  defp roles_and_text(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.map(&{&1.role, Message.text(&1)})
  end

  defp last_agent_role(conversation) do
    conversation
    |> Conversations.list_messages()
    |> List.last()
    |> Map.get(:agent_role)
  end

  setup do
    scope = full_scope_fixture()

    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        scope.active_account.id,
        scope.active_project.id,
        "live-runner-test"
      )

    # No tools: tool dispatch is exercised by the scripted path's tests and by
    # the spex. What is under test here is the loop around it.
    Application.put_env(:code_my_spec, :chat_tool_registry, __MODULE__.NoTools)
    Application.put_env(:code_my_spec, :chat_provider, ScriptedProvider)
    Application.delete_env(:code_my_spec, :chat_llm)

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :chat_provider)
      Application.delete_env(:code_my_spec, :chat_tool_registry)
    end)

    %{scope: scope, conversation: conversation}
  end

  defmodule NoTools do
    @moduledoc false
    @behaviour CodeMySpec.Chat.ToolRegistry
    @impl true
    def list_tools(_conversation), do: []
  end

  # --- tests ----------------------------------------------------------------

  describe "a plain reply" do
    test "persists the user turn and the assistant's answer", ctx do
      {:ok, _} = Replies.start([text_reply("What should it do?")])

      :ok = Runner.run(ctx.conversation, "I want a booking tool.")

      assert roles_and_text(ctx.conversation) == [
               {:user, "I want a booking tool."},
               {:assistant, "What should it do?"}
             ]
    end

    test "sends the conversation so far, not just the latest message", ctx do
      {:ok, _} = Replies.start([text_reply("first"), text_reply("second")])

      :ok = Runner.run(ctx.conversation, "one")
      :ok = Runner.run(ctx.conversation, "two")

      assert_received {:provider_called, _first, _}
      assert_received {:provider_called, messages, _}

      # The second call must carry the whole transcript: without it the model
      # re-asks question one forever and no interview ever reaches four answers.
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]
    end

    test "passes the system prompt and the tool list through", ctx do
      {:ok, _} = Replies.start([text_reply("ok")])

      :ok = Runner.run(ctx.conversation, "hello")

      assert_received {:provider_called, _messages, opts}
      assert opts[:system_prompt] =~ "exactly one user story"
      assert Keyword.has_key?(opts, :tools)
    end

    test "an empty reply writes no empty assistant turn", ctx do
      {:ok, _} = Replies.start([text_reply("")])

      :ok = Runner.run(ctx.conversation, "hello")

      assert roles_and_text(ctx.conversation) == [{:user, "hello"}]
    end
  end

  describe "a tool call" do
    test "is persisted as a call and a result, then the answer follows", ctx do
      {:ok, _} =
        Replies.start([
          tool_reply("list_stories", %{}, "Let me look."),
          text_reply("Nothing there yet.")
        ])

      :ok = Runner.run(ctx.conversation, "what do I have?")

      roles = ctx.conversation |> Conversations.list_messages() |> Enum.map(& &1.role)
      assert roles == [:user, :assistant, :assistant, :tool, :assistant]
    end

    test "feeds the result back to the provider on the next round", ctx do
      {:ok, _} =
        Replies.start([tool_reply("list_stories", %{}), text_reply("done")])

      :ok = Runner.run(ctx.conversation, "go")

      assert_received {:provider_called, _first, _}
      assert_received {:provider_called, messages, _}

      # The assistant turn carrying the call, then the result naming it. Without
      # the pairing the provider sees an answer to a question it never asked.
      assert %ReqLLM.Message{role: :tool, tool_call_id: "call_live_1"} = List.last(messages)
    end

    test "malformed argument JSON does not crash the turn", ctx do
      bad_call = ReqLLM.ToolCall.new("call_live_1", "list_stories", "{not json")

      {:ok, _} =
        Replies.start([
          response(%ReqLLM.Message{role: :assistant, content: [], tool_calls: [bad_call]}),
          text_reply("recovered")
        ])

      :ok = Runner.run(ctx.conversation, "go")

      assert {:assistant, "recovered"} = List.last(roles_and_text(ctx.conversation))
    end
  end

  describe "limits and failures" do
    test "a model that will not stop is halted, keeping what it wrote", ctx do
      # One more tool round than the cap allows.
      replies = for _ <- 1..(Runner.max_tool_rounds() + 1), do: tool_reply("list_stories", %{})
      {:ok, _} = Replies.start(replies)

      :ok = Runner.run(ctx.conversation, "loop forever")

      # A halt is a visible turn, not a status flag — see `Conversations.halt/2`:
      # "a silent stop is indistinguishable from a hang".
      assert last_agent_role(ctx.conversation) == "halted"

      # Everything already written survives the halt.
      roles = ctx.conversation |> Conversations.list_messages() |> Enum.map(& &1.role)
      assert :tool in roles
    end

    test "a provider error fails the conversation and keeps prior messages", ctx do
      {:ok, _} = Replies.start([{:error, "upstream exploded"}])

      :ok = Runner.run(ctx.conversation, "hello")

      assert last_agent_role(ctx.conversation) == "failed"

      # The reason reaches the reader rather than being swallowed.
      assert {_role, text} = List.last(roles_and_text(ctx.conversation))
      assert text =~ "upstream exploded"

      # "A failure mid-conversation keeps what Sam already said."
      assert {:user, "hello"} = hd(roles_and_text(ctx.conversation))
    end

    test "an unready provider says so rather than erroring obscurely", ctx do
      Application.put_env(:code_my_spec, :chat_provider, UnreadyProvider)

      :ok = Runner.run(ctx.conversation, "hello")

      assert last_agent_role(ctx.conversation) == "failed"

      # The exact text QA saw on every send before this was wired.
      assert {_role, text} = List.last(roles_and_text(ctx.conversation))
      assert text =~ "no model configured for this conversation"
    end
  end
end
