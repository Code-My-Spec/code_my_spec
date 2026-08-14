defmodule CodeMySpecSpex.Story984.Criterion8176Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8176 — The operator watches a running sprite without waiting for
  it to finish.

  A record that only becomes readable once the run ends is a transcript, not a
  window. The whole reason to watch is to catch a sprite going wrong at minute
  ten rather than reading about it at minute ninety — so a turn reported while
  the page is open has to arrive on that page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A running sprite can be watched live" do
    scenario "The operator watches a running sprite without waiting for it to finish" do
      given_ "the sprite is part-way through a run", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("start the first requirement"),
          Fixtures.model_response([Fixtures.text_block("Reading the spec now.")])
        )

        {:ok, context}
      end

      when_ "the operator opens the conversation while it is still running", context do
        {:ok, view, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert html =~ "start the first requirement",
               "expected the turns taken so far to be there on arrival"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "a further turn appears without reloading the page", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("move to the next requirement"),
          Fixtures.model_response([Fixtures.text_block("On to the next.")])
        )

        assert render(context.view) =~ "move to the next requirement",
               "expected the new turn to arrive on the already-open conversation"

        {:ok, context}
      end
    end
  end
end
