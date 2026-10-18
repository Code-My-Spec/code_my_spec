defmodule CodeMySpecSpex.Story1060.Criterion1983Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1983 — A coding agent's question about the project's state is
  answered outright.

  Rule: the main agent answers a question it can settle from what the project
  already records. 1221 (retired, superseded by this) established the shape
  for a product agent asking about ready stories; this is the same rule for a
  coding agent asking which working copy its own story's epic is built on —
  a fact recorded on another agent's own row, not on the asker's.
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

  spex "Which working copy an epic is built on is a fact the project already records",
    criterion: 1983 do
    scenario "a coding agent asks which working copy its story's epic is built on" do
      given_ "an epic already running on one working copy, and an asker whose story shares it",
             context do
        built_on = join_working_copy(context, "/tmp/spex-1983-built-on", "the built-on checkout")
        asker_copy = join_working_copy(context, "/tmp/spex-1983-asker", "the asker's checkout")
        scope = %{context.scope | active_working_copy_id: built_on.working_copy_id}

        epic = Fixtures.epic_fixture(scope, %{name: "Billing", slug: "billing-1983"})

        builder =
          Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-1983-built-on"
          )

        _builder = Fixtures.bind_agent(scope, builder, %{epic_id: epic.id})

        asker_scope = %{scope | active_working_copy_id: asker_copy.working_copy_id}
        story = Fixtures.authored_story(asker_scope, "Dunning emails go out")
        :ok = Fixtures.put_story_in_epic(asker_scope, story, epic)

        asker =
          Fixtures.running_agent(asker_scope,
            role: "coding",
            working_copy: "/tmp/spex-1983-asker"
          )

        asker = Fixtures.bind_agent(asker_scope, asker, %{story_id: story.id})
        # An on-duty main holds the question; with none, it goes to the user (1052, 2124).
        _main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-1983-main")

        asking = %Frame{assigns: %{current_scope: asker_scope, agent_id: asker.id}}

        asked =
          ToolLibrary.run(
            "ask_user_question",
            %{
              title: "which working copy is my epic built on",
              questions: [
                %{
                  "question" => "Which working copy is this story's epic built on?",
                  "options" => [
                    %{"label" => "/tmp/spex-1983-built-on"},
                    %{"label" => "/tmp/spex-1983-asker"}
                  ]
                }
              ]
            },
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, asked), inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:asker, asker)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent handles the question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        work =
          ToolLibrary.run(
            "list_agent_work",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, work), inspect(work)

        answered =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.question_id,
              answer: "/tmp/spex-1983-built-on",
              basis: "record"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :answered, answered)}
      end

      then_ "it answers with that working copy", context do
        assert match?({:ok, _}, context.answered), inspect(context.answered)

        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.asker.id}
        }

        response =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.question_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert response_text(response) =~ "/tmp/spex-1983-built-on",
               """
               The asking agent was not told which working copy its epic is built on.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end

      then_ "and the user is not asked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        listing =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        refute response_text(listing) =~ ~r/waiting on the user/i,
               """
               The user was interrupted by a fact the project already recorded on
               another agent's own row.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
