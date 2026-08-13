defmodule CodeMySpecSpex.Story984.Criterion2362Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2362 — A tool result stored with role user is not shown as the
  operator's words.

  The recorder writes a tool result as the *request* half of the next turn,
  because that is where the model put it: an Anthropic turn carries its results
  as user-role content blocks. So `role: :user` on this conversation means
  "whatever the model was sent", which is the operator's typing sometimes and a
  tool's output the rest of the time.

  Rendering role at face value made the 604 results in this project's history
  read as the operator's own chat bubbles — the single largest category in the
  transcript, every one of them attributed to a person who never typed it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A tool's output is never attributed to the operator" do
    scenario "A tool result stored with role user is not shown as the operator's words" do
      when_ "a turn carries a tool result back to the model", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request([
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_spex",
              "content" => "4 tests, 0 failures"
            }
          ]),
          Fixtures.model_response([%{"type" => "text", "text" => "The suite is green."}])
        )

        {:ok, context}
      end

      then_ "it renders as a tool result", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(view, "[data-test='tool-result']"),
               "the tool's output is a result, not something a person said"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "it is not rendered as the operator's own message", context do
        refute has_element?(context.view, "[data-test='message'][data-role='user']"),
               "a result attributed to the operator is the transcript claiming they " <>
                 "typed a tool's output"

        {:ok, context}
      end
    end
  end
end
