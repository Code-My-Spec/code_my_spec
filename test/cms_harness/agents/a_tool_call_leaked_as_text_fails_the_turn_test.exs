defmodule CmsHarness.Agents.AToolCallLeakedAsTextFailsTheTurnTest do
  @moduledoc """
  DeepSeek on DeepInfra sometimes returns a tool call as text in its own markup
  (`<｜DSML｜ parameter name="command" …>`) instead of a structured call. Nothing
  runs, the turn ends on that text, and the agent sits idle — 13 times on
  2026-10-06, each found only by an operator reading the transcript. A turn
  that ends that way failed, so it is reported as failed and re-offered.
  """
  use ExUnit.Case, async: false

  alias CmsHarnessTest.Machine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Machine.ensure_supervisor()
    %{root: tmp_dir}
  end

  # An OpenAI-compatible stream, the way DeepInfra answers.
  defp replying(text) do
    chunk = fn delta, finish ->
      "data: " <>
        Jason.encode!(%{
          "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
        }) <> "\n\n"
    end

    body = chunk.(%{"content" => text}, nil) <> chunk.(%{}, "stop") <> "data: [DONE]\n\n"

    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, body)
    end
  end

  defp start_agent(root, plug) do
    id = "agent-#{System.unique_integer([:positive])}"
    events = self()

    {:ok, _} =
      Machine.start_agent(id, root,
        provider: "deepinfra",
        api_key: "unused",
        req_options: [plug: plug],
        on_event: fn _agent_id, envelope -> send(events, {:event, envelope}) end
      )

    on_exit(fn -> Machine.stop_agent(id) end)
    id
  end

  test "a reply that is a tool call written as text fails the turn", %{root: root} do
    leaked =
      "Let me remove it.\n\n<parameter name=\"bash\">\n" <>
        "<｜DSML｜ parameter name=\"command\" string=\"true\">ls lib</parameter>"

    agent = start_agent(root, replying(leaked))
    assert {:ok, :started} = Machine.send_message(agent, "ref-a", "go")

    assert_receive {:event, %{event: :turn_failed, text: text}}, 5_000
    assert text =~ "tool call"
  end

  test "an ordinary reply does not", %{root: root} do
    agent = start_agent(root, replying("Done: three files changed."))
    assert {:ok, :started} = Machine.send_message(agent, "ref-a", "go")

    assert_receive {:event, %{event: :message, text: "Done: three files changed."}}, 5_000
    refute_receive {:event, %{event: :turn_failed}}, 500
  end
end
