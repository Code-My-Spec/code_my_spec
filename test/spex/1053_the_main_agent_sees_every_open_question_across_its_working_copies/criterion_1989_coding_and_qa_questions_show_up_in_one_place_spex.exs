defmodule CodeMySpecSpex.Story1053.Criterion1989Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question across its working
  copies.
  Criterion 1989 — Coding and QA questions show up in one place.

  Rule: the main agent sees every open question from every agent in its
  working copies. One list, regardless of which role asked.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
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

  spex "Every open question is listed regardless of which role asked", criterion: 1989 do
    scenario "a coding agent and a QA agent each have an open question" do
      given_ "a coding agent and a QA agent each with an open question", context do
        reply = join_working_copy(context, "/tmp/spex-1989", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-1989")
        qa = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-1989")

        coding_frame = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}
        qa_frame = %Frame{assigns: %{current_scope: scope, agent_id: qa.id}}

        coding_asked =
          ToolLibrary.run(
            "ask_user_question",
            %{
              questions: [
                %{
                  "question" => "Which branch should this build off of?",
                  "options" => [%{"label" => "main"}, %{"label" => "a feature branch"}]
                }
              ]
            },
            Map.put(coding_frame.assigns, :scope, coding_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, coding_asked), response_text(coding_asked)

        qa_asked =
          ToolLibrary.run(
            "ask_user_question",
            %{
              questions: [
                %{
                  "question" => "Is the staging environment the right place to run this?",
                  "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
                }
              ]
            },
            Map.put(qa_frame.assigns, :scope, qa_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, qa_asked), response_text(qa_asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:coding, coding)
         |> Map.put(:qa, qa)
         |> Map.put(:coding_question_id, Fixtures.question_id_from(response_text(coding_asked)))
         |> Map.put(:qa_question_id, Fixtures.question_id_from(response_text(qa_asked)))}
      end

      when_ "the main agent looks at what is waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, inbox, _} = ListNotifications.execute(%{}, frame)
        refute inbox.isError, response_text(inbox)
        {:ok, Map.put(context, :listing, response_text(inbox))}
      end

      then_ "both questions are listed, each naming the agent that asked", context do
        assert context.listing =~ context.coding_question_id and
                 context.listing =~ context.coding.id,
               """
               The coding agent's question is missing from the main agent's list,
               or does not name the coding agent as its asker.

               listing:
               #{context.listing}
               """

        assert context.listing =~ context.qa_question_id and
                 context.listing =~ context.qa.id,
               """
               The QA agent's question is missing from the main agent's list,
               or does not name the QA agent as its asker.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end
    end
  end
end
