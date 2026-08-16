defmodule CodeMySpec.AgentHarness.ConversationRecorderTest do
  @moduledoc """
  What a recorded turn leaves behind, driven through `record_turn/7` with the
  Anthropic payloads it actually receives.

  Two properties here were measured wrong before they were measured right, and
  both cost a browser round-trip to notice:

  1. The pairing between a call and its result, which the recorder used to drop
     — `block["id"]` was in scope and unread. Without it a result cannot render
     inside the call it answers, and 1330 of 1344 stored rows had no id.

  2. The repeat check, whose first version compared a request against the last
     message of *any* role. A turn writes results, then the request's free
     text, then the response, then the calls — so a request was always measured
     against the previous turn's response, never matched, and every repeat was
     written anyway. 132 duplicates in five minutes with that "fix" live.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentHarness.ConversationRecorder, as: Recorder
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message

  import CodeMySpec.UsersFixtures

  setup do
    scope = full_scope_fixture()

    %{
      account_id: scope.active_account_id,
      project_id: scope.active_project_id,
      session: "recorder-test"
    }
  end

  defp record(ctx, request, response) do
    :ok = Recorder.record_turn(ctx.account_id, ctx.project_id, ctx.session, request, response)
  end

  defp messages(ctx) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.account_id,
        ctx.project_id,
        ctx.session
      )

    Conversations.list_messages(conversation, limit: 200)
  end

  defp user_request(content), do: %{"messages" => [%{"role" => "user", "content" => content}]}

  defp call_block(id, name, input),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp result_block(id, text, error? \\ false),
    do: %{"type" => "tool_result", "tool_use_id" => id, "content" => text, "is_error" => error?}

  describe "a call and the result that answers it" do
    test "the call keeps the id the provider sent", ctx do
      record(ctx, user_request("read it"), %{
        "content" => [call_block("toolu_1", "Read", %{"file_path" => "mix.exs"})]
      })

      call = Enum.find(messages(ctx), &(&1.tool_calls not in [nil, []]))

      assert [%{"id" => "toolu_1", "name" => "Read", "arguments" => %{"file_path" => "mix.exs"}}] =
               call.tool_calls
    end

    test "the result carries the id of the call it answers", ctx do
      record(ctx, user_request("read it"), %{
        "content" => [call_block("toolu_1", "Read", %{"file_path" => "mix.exs"})]
      })

      record(ctx, %{"messages" => [%{"role" => "user", "content" => [result_block("toolu_1", "defmodule")]}]}, %{
        "content" => [%{"type" => "text", "text" => "done"}]
      })

      result = Enum.find(messages(ctx), &(&1.role == :tool))

      assert result.tool_call_id == "toolu_1"
      assert Message.text(result) == "defmodule"
      refute result.tool_failed
    end

    test "a failure is a field, not a prefix on the text", ctx do
      record(ctx, %{"messages" => [%{"role" => "user", "content" => [result_block("toolu_9", "boom", true)]}]}, %{
        "content" => [%{"type" => "text", "text" => "that failed"}]
      })

      result = Enum.find(messages(ctx), &(&1.role == :tool))

      assert result.tool_failed
      # The old shape folded this into the text and the view matched the string
      # back out, which made a rendering decision depend on parsing prose.
      refute Message.text(result) =~ "failed:"
      assert Message.text(result) == "boom"
    end

    test "parallel results each get their own row", ctx do
      record(
        ctx,
        %{
          "messages" => [
            %{
              "role" => "user",
              "content" => [
                result_block("t1", "one"),
                result_block("t2", "two"),
                result_block("t3", "three")
              ]
            }
          ]
        },
        %{"content" => [%{"type" => "text", "text" => "all three"}]}
      )

      results = Enum.filter(messages(ctx), &(&1.role == :tool))

      # Previously `join/1` concatenated every block of the last message into
      # one row, so which output belonged to which call was unrecoverable even
      # by position.
      assert length(results) == 3
      assert Enum.map(results, & &1.tool_call_id) |> Enum.sort() == ["t1", "t2", "t3"]
      assert Enum.map(results, &Message.text/1) |> Enum.sort() == ["one", "three", "two"]
    end
  end

  describe "a request that repeats the one before it" do
    test "an identical last message is not written twice", ctx do
      reminder = "The task tools haven't been used recently."

      record(ctx, user_request(reminder), %{"content" => [%{"type" => "text", "text" => "ok"}]})
      record(ctx, user_request(reminder), %{"content" => [%{"type" => "text", "text" => "still ok"}]})

      users = Enum.filter(messages(ctx), &(&1.role == :user))

      assert length(users) == 1
    end

    test "the check survives the rows a turn writes in between", ctx do
      # The regression that shipped: a turn writes the response after the
      # request, so comparing against the conversation's last message of any
      # role measured the request against that response and never matched.
      reminder = "same reminder"

      record(ctx, user_request(reminder), %{
        "content" => [call_block("toolu_a", "Bash", %{"command" => "ls"})]
      })

      record(ctx, user_request(reminder), %{
        "content" => [call_block("toolu_b", "Bash", %{"command" => "ls"})]
      })

      users = Enum.filter(messages(ctx), &(&1.role == :user))

      assert length(users) == 1,
             "a turn's own response must not hide the previous request from the check"
    end

    test "the same text after the agent has spoken is a real repeat", ctx do
      record(ctx, user_request("run it"), %{"content" => [%{"type" => "text", "text" => "ok"}]})
      record(ctx, user_request("something else"), %{"content" => [%{"type" => "text", "text" => "ok"}]})
      record(ctx, user_request("run it"), %{"content" => [%{"type" => "text", "text" => "ok"}]})

      texts = messages(ctx) |> Enum.filter(&(&1.role == :user)) |> Enum.map(&Message.text/1)

      assert texts == ["run it", "something else", "run it"]
    end
  end
end
