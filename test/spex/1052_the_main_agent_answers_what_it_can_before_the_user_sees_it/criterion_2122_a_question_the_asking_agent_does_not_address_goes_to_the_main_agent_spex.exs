defmodule CodeMySpecSpex.Story1052.Criterion2122Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2122 — A question the asking agent does not address goes to the
  main agent.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question the asking agent does not address goes to the main agent",
    criterion: 2122 do
    scenario "a coding agent asks without naming a recipient, with the main agent running" do
      given_ "a running main agent and a coding agent", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
         })}
      end

      when_ "the coding agent asks a question naming neither `to` nor `about`", context do
        params = %{
          questions: [
            %{
              "question" => "Which refund window applies?",
              "options" => [%{"label" => "30 days"}]
            }
          ]
        }

        reply =
          ToolLibrary.run(
            "ask_user_question",
            params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, reply), response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "it lands with the main agent", context do
        {:reply, listing, _frame} =
          ListNotifications.execute(
            %{},
            %Frame{assigns: %{current_scope: context.scope, agent_id: context.main_id}}
          )

        assert response_text(listing) =~ context.question_id,
               """
               An unaddressed question did not reach the main agent.

               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
