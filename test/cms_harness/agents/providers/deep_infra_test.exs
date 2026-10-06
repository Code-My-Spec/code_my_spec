defmodule CmsHarness.Agents.Providers.DeepInfraTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias CmsHarness.Agents.Providers.DeepInfra

  defp config(plug) do
    %{
      api_url: "http://deepinfra.test/v1/openai",
      chat_path: "/chat/completions",
      api_key: "test",
      model: "deepseek-ai/DeepSeek-V4.1-Flash",
      req_options: [plug: plug]
    }
  end

  defp reply(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  test "a tool call stored without an id goes out with one, and its result is paired with it" do
    test = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, Jason.decode!(raw)})

      reply(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "done"}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      })
    end

    history = [
      %Message{role: :user, content: "go"},
      %Message{
        role: :assistant,
        content: [%{type: "tool_use", id: nil, name: "get_next_requirement", input: %{}}]
      },
      %Message{role: :user, content: [%{type: "tool_result", tool_use_id: nil, content: "ok"}]}
    ]

    assert {:ok, _} = DeepInfra.complete(history, [], config(plug))
    assert_receive {:sent, %{"messages" => sent}}

    [%{"tool_calls" => [%{"id" => id}]}] = Enum.filter(sent, &Map.has_key?(&1, "tool_calls"))
    [%{"tool_call_id" => result_id}] = Enum.filter(sent, &(&1["role"] == "tool"))

    assert is_binary(id) and id != ""
    assert result_id == id
  end

  test "a response tool call without an id comes back with one" do
    plug = fn conn ->
      reply(conn, %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "type" => "function",
                  "function" => %{"name" => "get_next_requirement", "arguments" => "{}"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      })
    end

    assert {:ok, %{messages: [%Message{content: blocks}]}} =
             DeepInfra.complete([%Message{role: :user, content: "go"}], [], config(plug))

    assert [%{type: "tool_use", id: id}] = Enum.filter(blocks, &(&1[:type] == "tool_use"))
    assert is_binary(id) and id != ""
  end
end
