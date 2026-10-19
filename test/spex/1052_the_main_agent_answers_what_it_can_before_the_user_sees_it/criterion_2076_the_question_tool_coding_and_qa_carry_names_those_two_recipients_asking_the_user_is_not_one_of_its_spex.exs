defmodule CodeMySpecSpex.Story1052.Criterion2076Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2076 — The question tool coding and QA carry names those two
  recipients; asking the user is not one of its choices.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Asking the user is not one of the question tool's choices", criterion: 2076 do
    scenario "a coding agent tries to address a question straight to the user" do
      given_ "a running main agent and a coding agent", context do
        Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok,
         Map.put(context, :coder_frame, %Frame{
           assigns: %{current_scope: context.scope, agent_id: coder.id}
         })}
      end

      when_ "the coding agent names \"user\" as the recipient", context do
        params = %{
          to: "user",
          questions: [
            %{
              "question" => "Is this covered?",
              "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
            }
          ]
        }

        reply =
          ToolLibrary.run(
            "ask_question",
            params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, reply), response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))
        {:ok, Map.merge(context, %{question_id: question_id, ask_reply: reply})}
      end

      then_ "naming \"user\" has no effect — the main agent holds it instead", context do
        refute response_text(context.ask_reply) =~ ~r/waiting on a person, in their real inbox/i,
               """
               Naming "user" as `to` put the question straight in the user's \
               inbox, as if asking the user were a real choice.

               #{response_text(context.ask_reply)}
               """

        {:ok, view, _html} = live(context.conn, "/app/notifications")

        refute has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               The question reached the user even though "user" is not one of \
               the recipients this tool names.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
