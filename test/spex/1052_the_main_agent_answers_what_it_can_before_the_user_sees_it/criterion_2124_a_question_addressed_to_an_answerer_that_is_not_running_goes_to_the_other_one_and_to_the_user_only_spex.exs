defmodule CodeMySpecSpex.Story1052.Criterion2124Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2124 — A question addressed to an answerer that is not running
  goes to the other one, and to the user only when neither is running.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question addressed to an answerer that is not running falls back to the other",
       criterion: 2124 do
    scenario "the coder names product, but only main is running" do
      given_ "a running main agent, no product agent, and a coding agent", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
         })}
      end

      when_ "the coder asks for product by name", context do
        params = %{
          to: "product",
          questions: [%{"question" => "Should this surface a warning?", "options" => []}]
        }

        {:reply, reply, _frame} = AskUserQuestion.execute(params, context.coder_frame)
        refute reply.isError, response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "it falls to the main agent instead", context do
        {:reply, listing, _frame} =
          ListNotifications.execute(
            %{},
            %Frame{assigns: %{current_scope: context.scope, agent_id: context.main_id}}
          )

        assert response_text(listing) =~ context.question_id,
               """
               A question addressed to product, who was not running, did not \
               fall back to the main agent, who was.

               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end

  spex "A question reaches the user only when neither the main agent nor the product agent is running",
       criterion: 2124 do
    scenario "neither the main agent nor the product agent is running" do
      given_ "a coding agent, with no main or product agent running", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok,
         Map.put(context, :coder_frame, %Frame{
           assigns: %{current_scope: context.scope, agent_id: coder.id}
         })}
      end

      when_ "the coder asks a plain question", context do
        params = %{
          questions: [%{"question" => "Should this surface a warning?", "options" => []}]
        }

        {:reply, reply, _frame} = AskUserQuestion.execute(params, context.coder_frame)
        refute reply.isError, response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "it reaches the user, since neither answerer is up", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               With neither main nor product running, the question never \
               reached the user either.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
