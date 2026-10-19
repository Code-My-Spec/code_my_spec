defmodule CodeMySpecSpex.Story1017.Criterion2422Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2422 — Both question hosts support choices and one free-text question.

  Each case creates exactly one question through ask_question, opens both
  real hosts, answers from one, and collects the saved answer through MCP.
  Separate cases keep a failure in free-text creation from hiding choice coverage.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @question "Which behavior should the agent implement?"
  @answer "Preserve the existing behavior"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup context do
    agent = Fixtures.running_agent(context.scope, role: "coding")

    {:ok,
     frame: %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}},
     conversation_path: Fixtures.agent_conversation_path(context.scope, agent)}
  end

  spex "structured choices answered from question_page", criterion: 915 do
    scenario "Both hosts display the form and the saved answer is available through MCP" do
      given_ "the agent asks one structured choices question", context do
        response =
          ToolLibrary.run(
            "ask_question",
            %{
              questions: [
                %{
                  question: @question,
                  options: [%{label: @answer}, %{label: "Change the behavior"}]
                }
              ]
            },
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(response))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the user opens the question page and conversation", context do
        {:ok, question_page, _} = live(context.conn, "/app/questions/#{context.question_id}")
        {:ok, conversation, _} = live(context.conn, context.conversation_path)
        {:ok, Map.merge(context, %{question_page: question_page, conversation: conversation})}
      end

      then_ "both hosts render the expected input in the shared question form", context do
        assert has_element?(
                 context.question_page,
                 "main [data-test='question-form'] input[type='radio'][name='q_0']"
               )

        assert has_element?(
                 context.conversation,
                 "main [data-test='question-form'] input[type='radio'][name='q_0']"
               )

        assert render(context.question_page) =~ @question
        assert render(context.conversation) =~ @question
        {:ok, context}
      end

      then_ "answering from question_page saves the answer for the agent", context do
        context.question_page
        |> form("main [data-test='question-form']", %{"q_0" => @answer})
        |> render_submit()

        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ @answer
        assert response_text(answer) =~ "The user replied"
        assert render(context.question_page) =~ "Answer sent."
        assert render(context.question_page) =~ @answer
        {:ok, context}
      end
    end
  end

  spex "structured choices answered from conversation" do
    scenario "Both hosts display the form and the saved answer is available through MCP" do
      given_ "the agent asks one structured choices question", context do
        response =
          ToolLibrary.run(
            "ask_question",
            %{
              questions: [
                %{
                  question: @question,
                  options: [%{label: @answer}, %{label: "Change the behavior"}]
                }
              ]
            },
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(response))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the user opens the question page and conversation", context do
        {:ok, question_page, _} = live(context.conn, "/app/questions/#{context.question_id}")
        {:ok, conversation, _} = live(context.conn, context.conversation_path)
        {:ok, Map.merge(context, %{question_page: question_page, conversation: conversation})}
      end

      then_ "both hosts render the expected input in the shared question form", context do
        assert has_element?(
                 context.question_page,
                 "main [data-test='question-form'] input[type='radio'][name='q_0']"
               )

        assert has_element?(
                 context.conversation,
                 "main [data-test='question-form'] input[type='radio'][name='q_0']"
               )

        assert render(context.question_page) =~ @question
        assert render(context.conversation) =~ @question
        {:ok, context}
      end

      then_ "answering from conversation saves the answer for the agent", context do
        context.conversation
        |> form("main [data-test='question-form']", %{"q_0" => @answer})
        |> render_submit()

        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ @answer
        assert response_text(answer) =~ "The user replied"
        assert render(context.question_page) =~ "Answer sent."
        assert render(context.question_page) =~ @answer
        {:ok, context}
      end
    end
  end

  spex "free text answered from question_page" do
    scenario "Both hosts display the form and the saved answer is available through MCP" do
      given_ "the agent asks one free text question", context do
        response =
          ToolLibrary.run(
            "ask_question",
            %{questions: [%{question: @question, options: []}]},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(response))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the user opens the question page and conversation", context do
        {:ok, question_page, _} = live(context.conn, "/app/questions/#{context.question_id}")
        {:ok, conversation, _} = live(context.conn, context.conversation_path)
        {:ok, Map.merge(context, %{question_page: question_page, conversation: conversation})}
      end

      then_ "both hosts render the expected input in the shared question form", context do
        assert has_element?(
                 context.question_page,
                 "main [data-test='question-form'] textarea[name='q_0']"
               )

        assert has_element?(
                 context.conversation,
                 "main [data-test='question-form'] textarea[name='q_0']"
               )

        assert render(context.question_page) =~ @question
        assert render(context.conversation) =~ @question
        {:ok, context}
      end

      then_ "answering from question_page saves the answer for the agent", context do
        context.question_page
        |> form("main [data-test='question-form']", %{"q_0" => @answer})
        |> render_submit()

        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ @answer
        assert response_text(answer) =~ "The user replied"
        assert render(context.question_page) =~ "Answer sent."
        assert render(context.question_page) =~ @answer
        {:ok, context}
      end
    end
  end

  spex "free text answered from conversation" do
    scenario "Both hosts display the form and the saved answer is available through MCP" do
      given_ "the agent asks one free text question", context do
        response =
          ToolLibrary.run(
            "ask_question",
            %{questions: [%{question: @question, options: []}]},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(response))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the user opens the question page and conversation", context do
        {:ok, question_page, _} = live(context.conn, "/app/questions/#{context.question_id}")
        {:ok, conversation, _} = live(context.conn, context.conversation_path)
        {:ok, Map.merge(context, %{question_page: question_page, conversation: conversation})}
      end

      then_ "both hosts render the expected input in the shared question form", context do
        assert has_element?(
                 context.question_page,
                 "main [data-test='question-form'] textarea[name='q_0']"
               )

        assert has_element?(
                 context.conversation,
                 "main [data-test='question-form'] textarea[name='q_0']"
               )

        assert render(context.question_page) =~ @question
        assert render(context.conversation) =~ @question
        {:ok, context}
      end

      then_ "answering from conversation saves the answer for the agent", context do
        context.conversation
        |> form("main [data-test='question-form']", %{"q_0" => @answer})
        |> render_submit()

        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ @answer
        assert response_text(answer) =~ "The user replied"
        assert render(context.question_page) =~ "Answer sent."
        assert render(context.question_page) =~ @answer
        {:ok, context}
      end
    end
  end
end
