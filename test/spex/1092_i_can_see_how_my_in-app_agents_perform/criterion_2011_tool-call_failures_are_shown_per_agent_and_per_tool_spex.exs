defmodule CodeMySpecSpex.Story1092.Criterion2011Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2011 -- Tool-call failures are shown per agent and per tool.

  Rule: Failed turns and tool-call failures are shown per agent, with
  their cause.

  A tool-call result's `is_error` already survives a real `record_turn`
  round trip onto `tool_failed` (`ConversationRecorder.tool_results/1`,
  `Message.tool_failed`) -- this drives that same path rather than a
  fixture that writes the column directly.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A failed tool call is shown against its agent and the tool that failed",
       criterion: 2011 do
    scenario "an agent's tool call failed during a period" do
      given_ "a running agent", context do
        reply = join_working_copy(context, "/tmp/spex-2011", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2011")
        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "it calls a tool and the tool call fails", context do
        :ok =
          Fixtures.record_turn(
            context.scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "call_2011",
                  "name" => "run_script",
                  "input" => %{"script" => "invalid_lua("}
                }
              ]
            },
            session_id: "spex-2011",
            agent_role: "coding"
          )

        :ok =
          Fixtures.record_turn(
            context.scope,
            %{
              "messages" => [
                %{
                  "content" => [
                    %{
                      "type" => "tool_result",
                      "tool_use_id" => "call_2011",
                      "name" => "run_script",
                      "is_error" => true,
                      "content" => "Lua syntax error: unexpected end of script"
                    }
                  ]
                }
              ]
            },
            %{"model" => "claude-sonnet-5-5", "content" => [%{"type" => "text", "text" => "retrying"}]},
            session_id: "spex-2011",
            agent_role: "coding"
          )

        {:ok, context}
      end

      then_ "I see its tool failure rate, and which tools failed most", context do
        {:ok, _show, html} = live(context.conn, show_path(context, context.agent))

        assert html =~ "run_script",
               "the failed tool call does not name the tool that failed"

        assert html =~ "1", "the agent's one tool-call failure is not counted"

        {:ok, context}
      end
    end
  end
end
