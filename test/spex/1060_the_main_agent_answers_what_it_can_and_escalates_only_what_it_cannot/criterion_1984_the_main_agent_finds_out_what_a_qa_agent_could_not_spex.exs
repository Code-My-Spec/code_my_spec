defmodule CodeMySpecSpex.Story1060.Criterion1984Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1984 — The main agent finds out what a QA agent could not.

  Rule: the main agent does work to answer a question — reading, querying,
  asking another agent — before putting it to the user. 1225 (retired,
  superseded by this) established that "I do not know" is where the work
  starts, not where it ends, for a product agent asking about ready stories.
  This is the same rule for a QA agent asking something about its own copy
  it genuinely cannot see from where it sits.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Not knowing which commit a QA agent's own app is serving is a reason to look",
    criterion: 1984 do
    scenario "a QA agent cannot see which commit its own copy's app is serving" do
      given_ "a blocked QA agent and a copy whose app the main agent can check", context do
        reply = join_working_copy(context, "/tmp/spex-1984", "the QA checkout")
        qa_scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # An on-duty main holds the question; with none, it goes to the user (1052, 2124).

        _main =
          Fixtures.running_agent(qa_scope, role: "main", working_copy: "/tmp/spex-1984-main")

        qa_agent =
          Fixtures.running_agent(qa_scope, role: "qa", working_copy: "/tmp/spex-1984")

        asking = %Frame{assigns: %{current_scope: qa_scope, agent_id: qa_agent.id}}

        asked =
          ToolLibrary.run(
            "ask_user_question",
            %{
              title: "cannot see what my app is serving",
              questions: [
                %{
                  "question" => "Which commit is my copy's app serving right now?",
                  "options" => [%{"label" => "current HEAD"}, %{"label" => "something older"}]
                }
              ]
            },
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, asked), inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, qa_scope)
         |> Map.put(:qa_agent, qa_agent)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "it handles the question", context do
        # Nothing was handed to it. If it can answer, it went and checked —
        # by reading what the QA agent itself has already said about its own
        # copy, rather than asking the QA agent to stop and look again.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        read =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.qa_agent.id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, read), inspect(read)

        answered =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.question_id,
              answer: "Your copy /tmp/spex-1984's app is serving the current HEAD commit.",
              basis: "record"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :answered, answered)}
      end

      then_ "it looks the answer up itself and answers the QA agent", context do
        assert match?({:ok, _}, context.answered), inspect(context.answered)

        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.qa_agent.id}
        }

        response =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert response_text(response) =~ ~r/serving/i,
               """
               The main agent could have checked what the QA agent's own app is
               serving and did not.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "without involving the user", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        listing =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The user was asked something the main agent could have checked itself.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
