defmodule CodeMySpecSpex.Story984.Criterion2363Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2363 — A failed tool result is distinguishable from one that
  succeeded.

  A failed result is where a run starts going wrong, usually several turns
  before the agent says anything about it. The recorder already keeps the
  distinction — `is_error` becomes "← failed:" rather than "← result:" — and
  then the view spent it, rendering both as the same grey block. An operator
  scanning for the moment it went bad had to read every result to find the one
  that mattered.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A failure is visible without reading it" do
    scenario "A failed tool result is distinguishable from one that succeeded" do
      when_ "one tool call fails and another succeeds", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request([
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_ok",
              "content" => "4 tests, 0 failures"
            }
          ]),
          Fixtures.model_response([%{"type" => "text", "text" => "Green."}])
        )

        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request([
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_bad",
              "is_error" => true,
              "content" => "no such file or directory"
            }
          ]),
          Fixtures.model_response([%{"type" => "text", "text" => "Retrying."}])
        )

        {:ok, context}
      end

      then_ "the failure is marked as one", context do
        {:ok, view, _html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='tool-result'][data-failed='true']"),
               "a failed result has to be findable without reading its text"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the successful one is not", context do
        refute has_element?(
                 context.view,
                 "[data-test='tool-result'][data-failed='true'][data-tool-call-id='toolu_ok']"
               ),
               "marking every result failed would be the same blindness in reverse"

        {:ok, context}
      end
    end
  end
end
