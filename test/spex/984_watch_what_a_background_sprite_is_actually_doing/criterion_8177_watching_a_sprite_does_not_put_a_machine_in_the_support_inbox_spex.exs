defmodule CodeMySpecSpex.Story984.Criterion8177Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8177 — Watching a sprite does not put a machine in the support
  inbox.

  The support inbox is where a person is writing to you. A sprite is a machine
  talking to a model, and it produces far more traffic than any customer does.
  Let it in and the inbox stops meaning "someone needs you" — which is the only
  thing an inbox is for.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sprite conversations stay out of the support inbox" do
    scenario "Watching a sprite does not put a machine in the support inbox" do
      given_ "a sprite has been recording its agent's turns", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("audit the requirement graph"),
          Fixtures.model_response([Fixtures.text_block("Graph looks consistent.")])
        )

        {:ok, context}
      end

      when_ "the operator opens the customer support inbox", context do
        {:ok, view, html} = live(context.conn, "/app/projects/#{context.project.id}/inbox")

        {:ok, context |> Map.put(:inbox, view) |> Map.put(:inbox_html, html)}
      end

      then_ "the sprite's conversation is not listed among the customer conversations",
            context do
        refute context.inbox_html =~ "audit the requirement graph",
               "a sprite's turns must not appear in the support inbox"

        refute has_element?(context.inbox, "[data-test='conversation'][data-kind='agent']"),
               "expected no agent conversation among the customer conversations"

        {:ok, context}
      end

      and_ "no unread indicator is raised for it", context do
        refute has_element?(context.inbox, "[data-test='inbox-unread']"),
               "a machine's chatter must not make the inbox look like someone is waiting"

        {:ok, context}
      end

      and_ "the sprite's conversation is reachable from its own project instead", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "audit the requirement graph",
               "the turns still have to be readable where an operator goes looking for them"

        {:ok, context}
      end
    end
  end
end
