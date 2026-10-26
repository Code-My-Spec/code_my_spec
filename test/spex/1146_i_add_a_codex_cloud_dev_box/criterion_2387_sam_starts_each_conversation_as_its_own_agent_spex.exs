defmodule CodeMySpecSpex.Story1146.Criterion2387Spex do
  @moduledoc "Exercises the shipped CLI against an external harness boundary; full release installation is integration QA."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.CodexCloudHelpers

  spex "Sam starts each conversation as its own agent", criterion: 2387 do
    scenario "Two Codex threads initialize independent MCP sessions" do
      given_ "a prepared generation target and its harness boundary", context do
        context = prepared_cloud(context)

        {:ok, context}
      end

      when_ "Sam runs the cloud environment command", context do
        first = cloud_command(context, "session", "codex-thread-one")
        second = cloud_command(context, "session", "codex-thread-two")
        {:ok, Map.merge(context, %{first: first, second: second})}
      end

      then_ "the command enforces the required lifecycle", context do
        assert context.first.status == 0, context.first.output
        assert context.second.status == 0, context.second.output
        requests = cloud_requests(context)
        hooks = Enum.filter(requests, &String.ends_with?(&1.path, "/hooks/session-start"))

        assert Enum.map(hooks, & &1.body["session_id"]) == [
                 "codex-thread-one",
                 "codex-thread-two"
               ]

        assert Enum.all?(hooks, &(&1.body["engine"] == "codex"))
        mcp = Enum.filter(requests, &(&1.path == "/mcp"))

        assert Enum.map(mcp, & &1.body["method"]) ==
                 List.duplicate(["initialize", "notifications/initialized", "tools/list"], 2)
                 |> List.flatten()

        agents =
          Enum.map(mcp, fn request ->
            List.keyfind(request.headers, "x-agent-id", 0) |> elem(1)
          end)

        assert Enum.uniq(agents) |> length() == 2

        assert Enum.all?(mcp, fn request ->
                 List.keyfind(request.headers, "x-harness-id", 0) != nil
               end)

        {:ok, context}
      end
    end
  end
end
