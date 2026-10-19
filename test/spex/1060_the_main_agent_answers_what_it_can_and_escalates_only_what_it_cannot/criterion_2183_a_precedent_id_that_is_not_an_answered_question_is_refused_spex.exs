defmodule CodeMySpecSpex.Story1060.Criterion2183Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2183 — A precedent id that is not an answered question is
  refused.

  2182 drops the text-equality check that criterion 1228 enforced, but the
  basis is still a claim about the project, checked rather than taken on
  trust: `precedent_id` has to resolve to a real, answered question. A main
  agent citing an id that does not, or one still open, is still a guess
  (criterion 1224).
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

  spex "A precedent id that names nothing answered is refused", criterion: 2183 do
    scenario "the cited id is not a real question at all" do
      given_ "a coding agent's question", context do
        reply = join_working_copy(context, "/tmp/spex-2183", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2183-main")
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2183")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        asked =
          ToolLibrary.run(
            "ask_question",
            %{
              title: "a question with no real precedent",
              questions: [%{"question" => "Should this feature exist?", "options" => []}]
            },
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, asked), inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent cites a precedent id that answers nothing real", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.question_id,
              answer: "Yes, per an earlier decision",
              basis: "precedent",
              precedent_id: Ecto.UUID.generate()
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is refused", context do
        assert match?({:error, _}, context.response),
               """
               A precedent id naming nothing real was accepted as grounds for an
               answer.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the question goes to the user", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        listing =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert response_text(listing) =~ ~r/waiting on the user/i,
               """
               A refused, unfounded precedent left the question nowhere rather
               than escalating it.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
