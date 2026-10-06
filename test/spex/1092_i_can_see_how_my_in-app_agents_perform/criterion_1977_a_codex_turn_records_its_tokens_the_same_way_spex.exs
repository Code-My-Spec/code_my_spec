defmodule CodeMySpecSpex.Story1092.Criterion1977Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1977 -- A Codex turn records its tokens the same way.

  Rule: Token usage is recorded per agent turn and rolled up per story,
  per agent and per provider, whichever provider ran the turn.
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

  spex "A Codex QA turn's tokens are recorded in the same shape as a Claude Code turn",
       criterion: 1977 do
    scenario "a QA agent on Codex finishes a turn" do
      given_ "a QA agent running on Codex", context do
        reply = join_working_copy(context, "/tmp/spex-1977", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          Fixtures.running_agent(scope,
            role: "qa",
            provider: "openai",
            working_copy: "/tmp/spex-1977"
          )

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the turn ends", context do
        :ok =
          Fixtures.record_turn(
            context.scope,
            %{"model" => "gpt-5-codex", "messages" => []},
            %{
              "model" => "gpt-5-codex",
              "content" => [%{"type" => "text", "text" => "probed and passed"}],
              "usage" => %{"input_tokens" => 210, "output_tokens" => 95}
            },
            session_id: "spex-1977",
            agent_role: "qa"
          )

        {:ok, context}
      end

      then_ "its tokens are shown in the same labeled form as a Claude Code turn", context do
        {:ok, show, html} = live(context.conn, show_path(context, context.agent))

        assert html =~ "210", "the Codex turn's input tokens are not shown"
        assert html =~ "95", "the Codex turn's output tokens are not shown"

        assert render(show) =~ "openai",
               "the Codex turn is not shown with its provider"

        assert render(show) =~ "gpt-5-codex",
               "the Codex turn is not shown with its model"

        {:ok, context}
      end
    end
  end
end
