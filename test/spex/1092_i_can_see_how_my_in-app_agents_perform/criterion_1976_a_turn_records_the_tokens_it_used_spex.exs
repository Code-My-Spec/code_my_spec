defmodule CodeMySpecSpex.Story1092.Criterion1976Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1976 -- A turn records the tokens it used.

  Rule: Token usage is recorded per agent turn and rolled up per story,
  per agent and per provider.
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

  spex "A finished Claude Code turn is recorded with what it cost", criterion: 1976 do
    scenario "a coding agent on Claude Code finishes a turn" do
      given_ "a coding agent running on Claude Code", context do
        reply = join_working_copy(context, "/tmp/spex-1976", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          Fixtures.running_agent(scope,
            role: "coding",
            provider: "anthropic",
            working_copy: "/tmp/spex-1976"
          )

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the turn ends", context do
        :ok =
          Fixtures.record_turn(
            context.scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{
                "input_tokens" => 120,
                "output_tokens" => 340,
                "cache_read_input_tokens" => 50,
                "cache_creation_input_tokens" => 10
              }
            },
            session_id: "spex-1976",
            agent_role: "coding"
          )

        {:ok, context}
      end

      then_ "its input, output, cache-read and cache-write tokens are shown", context do
        {:ok, show, html} = live(context.conn, show_path(context, context.agent))

        assert html =~ "120", "the turn's input tokens are not shown on its agent's page"
        assert html =~ "340", "the turn's output tokens are not shown on its agent's page"
        assert html =~ "50", "the turn's cache-read tokens are not shown on its agent's page"
        assert html =~ "10", "the turn's cache-write tokens are not shown on its agent's page"

        {:ok, Map.put(context, :show, show)}
      end

      then_ "with the agent, provider and model that ran it", context do
        assert render(context.show) =~ "anthropic",
               "the turn is not shown with the provider that ran it"

        assert render(context.show) =~ "claude-sonnet-5-5",
               "the turn is not shown with the model that ran it"

        {:ok, context}
      end
    end
  end
end
