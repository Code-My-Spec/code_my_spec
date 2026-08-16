defmodule CodeMySpecSpex.Story984.Criterion2374Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2374 — Output stored with role tool is not passed off as a tool
  name.

  The writer ambiguity, showing up on screen. `ConversationRecorder` writes a
  tool *call* with `role: :tool`, and `Conversations.add_tool_result/4` writes a
  tool *result* with the same role. This view declares that role means "call",
  so a result stored that way has its first line presented as the tool the agent
  used.

  Measured: "Showing 1-1 of 1 stories:" is rendered as a tool name twelve times
  in this project's history. It is not a tool. Nothing the agent did is named
  there — the reader is being told a story about a tool that never ran.

  Until the writers agree, the view has to notice: a tool name is one token, and
  output is not.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Output is not mistaken for the name of a tool" do
    scenario "Output stored with role tool is not passed off as a tool name" do
      when_ "a tool's output is stored with role tool", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("list the stories"),
          Fixtures.model_response([Fixtures.tool_block("list_stories", %{})])
        )

        :ok =
          Fixtures.chat_tool_result(
            context.scope,
            "call_0",
            "list_stories",
            "Showing 1-1 of 1 stories:\n- A story (ID: 1)"
          )

        {:ok, context}
      end

      then_ "it renders as a result", context do
        {:ok, view, _html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='tool-result']"),
               "output is a result whichever role it was stored under"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "its first line is not offered as a tool that was used", context do
        refute has_element?(
                 context.view,
                 "[data-test='tool-call'][data-tool='Showing 1-1 of 1 stories:']"
               ),
               "naming a tool that never ran is the transcript inventing a turn"

        {:ok, context}
      end
    end
  end
end
