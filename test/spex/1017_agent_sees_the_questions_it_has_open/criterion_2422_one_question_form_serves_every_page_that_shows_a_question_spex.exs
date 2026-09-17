defmodule CodeMySpecSpex.Story1017.Criterion2422Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2422 — One question form serves every page that shows a question.

  The rule:

  > A question is answered the same way wherever it is shown.

  ## What a second form would cost

  A question turns up in more than one place — its own page, the agent's
  transcript, the notification dropdown — and each is a reasonable place to
  answer from. The failure this guards against is not a page missing the form
  but two pages growing their own: one renders radio buttons and the other a
  text box, multi-select works in one and not the other, and an answer recorded
  from the wrong one arrives in a shape `check_answer` cannot read. None of that
  looks broken from inside either page.

  `ChatComponents.question/1` is the one form, marked `data-test="question-form"`.
  Both hosts pass their own `@on_submit` and `@target` into it and both land on
  `Notifications.answer_question_request/2`.

  ## One question, shown twice, answered once

  An earlier draft opened two questions and answered one on each page, to compare
  the recorded answers. That fights a design assumption rather than testing one:
  `AgentConversationLive`'s handler says "a conversation can hold several, and
  only one is ever pending, so that is the one being answered" — the submitted
  form does not name its question. With two pending on one agent, a submit aimed
  at the second answers the first, and the scenario measures that instead of
  anything the criterion is about.

  So it is one question, open on both pages at once, answered on the transcript.
  The claim lands harder this way: the *other* page, which was never submitted,
  shows the answer. That is only true if both are reading and writing one
  record, which is the whole of "one form serves every page" — two
  implementations that happened to agree would not propagate.

  `QuestionLive.Show` subscribes to `question_request:<id>`, so the update
  arrives without a reload.

  ## Surface

  The MCP tool to ask — with an `agent_id` on the frame, which is what ties a
  question to a transcript rather than a session — and the two LiveViews.
  `agent_conversation_path/2` rather than a hand-built URL, because the
  conversation is created inside that call and the route needs its id in the
  query string.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentToolsHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  @question "Which approach do you want here?"
  @answer "The second one"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A question is answered the same way wherever it is shown" do
    scenario "one open question, shown on its own page and in the transcript" do
      given_ "an agent with a conversation", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "a question it asked is open", context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: @question,
                  header: "Approach",
                  multiSelect: false,
                  options: [
                    %{label: "The first one", description: "keep the existing shape"},
                    %{label: @answer, description: "rewrite it"}
                  ]
                }
              ]
            },
            frame
          )

        refute response.isError, response_text(response)

        {:ok, Map.put(context, :id, question_id!(response_text(response)))}
      end

      when_ "the user opens the question's own page and the transcript it was asked in",
            context do
        {:ok, own_page, own_html} = live(context.conn, "/app/questions/#{context.id}")

        {:ok, transcript, transcript_html} =
          live(
            context.conn,
            Fixtures.agent_conversation_path(context.scope, %{id: context.agent_id})
          )

        {:ok,
         context
         |> Map.put(:own_page, own_page)
         |> Map.put(:own_html, own_html)
         |> Map.put(:transcript, transcript)
         |> Map.put(:transcript_html, transcript_html)}
      end

      then_ "both render the same question form component", context do
        assert context.own_html =~ ~s(data-test="question-form"),
               """
               The question's own page does not render the shared form. That page
               exists to answer a question and is where every notification links.
               """

        assert context.transcript_html =~ ~s(data-test="question-form"),
               """
               The transcript does not render the shared form.

               A question an agent asked is shown in that agent's transcript,
               which is where somebody reading what it is doing meets it. Showing
               it without the form sends the reader somewhere else to answer the
               thing they are already looking at.
               """

        {:ok, context}
      end

      then_ "and answering from either records the same answer", context do
        # Scoped to `main` for the same reason 2419 is: with a question pending,
        # the notification dropdown renders its own copy on every authenticated
        # page, and an unscoped selector matches that too.
        context.transcript
        |> form("main [data-test='question-form']", %{"q_0" => @answer})
        |> render_submit()

        own = render(context.own_page)

        assert own =~ "Answer sent.",
               """
               The question was answered on the transcript and its own page still
               shows it open.

               Nothing was submitted on that page, so the only way it can know is
               by reading the record the transcript wrote. A page that does not
               is answering into its own copy, and an agent collecting the reply
               gets whichever one it happens to read.
               """

        assert own =~ @answer,
               """
               The page shows the question as answered without the answer that
               was given.

               `check_answer` reads this back, so an answer recorded in a shape
               one page renders and the other cannot is exactly the divergence a
               shared form exists to prevent.
               """

        {:ok, context}
      end
    end
  end

  defp question_id!(body) do
    captured!(
      Regex.run(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, body),
      body
    )
  end

  defp captured!([id], _body), do: id
  defp captured!(_no_match, body), do: raise("could not read a question id from: #{body}")
end
