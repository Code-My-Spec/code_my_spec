defmodule CodeMySpecSpex.Story984.Criterion8171Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8171 — A completed turn leaves a request and a response
  on the conversation.

  Surface: the harness channel, observed through the operator's conversation
  LiveView.

  This used to dispatch at the local endpoint, because the proxy lived in the
  CLI app. It does not: a sprite runs `cms_harness`, which is where the proxy
  is now, and the record reaches the server over the channel the same way
  observations do. A spec here cannot drive a process on the sprite, and does
  not need to — what the server owns is what it does with a turn once it
  arrives.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A sprite's agent turn is recorded" do
    scenario "A completed turn leaves a request and a response on the conversation" do
      when_ "a sprite reports one completed model turn", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("count the open problems"),
          Fixtures.model_response([Fixtures.text_block("There are 3 open problems.")])
        )

        {:ok, context}
      end

      then_ "the operator's conversation shows what the agent was asked", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "count the open problems",
               "expected the turn's request to appear on the conversation"

        {:ok, context}
      end

      and_ "it shows what the model answered", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert has_element?(view, "[data-test='message'][data-role='user']"),
               "expected a user-role message for the request"

        assert has_element?(view, "[data-test='message'][data-role='assistant']"),
               "expected an assistant-role message for the response"

        {:ok, context}
      end
    end
  end
end
