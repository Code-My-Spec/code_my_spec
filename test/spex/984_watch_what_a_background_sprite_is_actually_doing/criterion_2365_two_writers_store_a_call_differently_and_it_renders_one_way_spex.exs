defmodule CodeMySpecSpex.Story984.Criterion2365Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2365 — Two writers store a call differently and it renders one way.

  `ConversationRecorder.write_tool_calls/3` stores a call as a `role: :tool`
  message whose text is the tool name and its arguments.
  `Conversations.add_tool_call/4` — the path the in-app chat uses — stores one
  as an assistant message with empty content and a populated `tool_calls`
  array.

  Same event, two shapes, because two writers grew separately. Until they
  agree, the view is where the disagreement is absorbed, and it has to be
  absorbed completely: a reader should not be able to tell which writer
  produced a call.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Both storage shapes render as a call" do
    scenario "Two writers store a call differently and it renders one way" do
      when_ "the recorder stores one call and the chat path stores another", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("list the stories"),
          Fixtures.model_response([Fixtures.tool_block("list_stories", %{"limit" => 5})])
        )

        :ok =
          Fixtures.chat_tool_call(context.scope, "call_0", "create_story", %{
            "title" => "A story"
          })

        {:ok, context}
      end

      then_ "the recorder's call renders as a call", context do
        {:ok, view, _html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='tool-call'][data-tool='list_stories']")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the chat path's call renders the same way", context do
        assert has_element?(context.view, "[data-test='tool-call'][data-tool='create_story']"),
               "a reader should not be able to tell which writer stored a call"

        {:ok, context}
      end
    end
  end
end
