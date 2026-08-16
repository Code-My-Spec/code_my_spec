defmodule CodeMySpecSpex.Story995.Criterion8269Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8269 — A second story is refused not silently added.

  Rule: The conversation produces exactly one story.

  A model that keeps going is the likely failure, not a rare one. If a second
  create slips through, Sam's payout stops being one clear thing and becomes a
  list he has to sort out — which is what the guided path exists to spare him.

  The two scripted calls carry **different** titles on purpose. They used to
  share one, and that made this criterion pass without the rule existing: two
  stories with the same title trip a unique index, so the database refused the
  second and the spex read that as the conversation refusing it. A model naming
  its second story differently — the likely case, since it would be describing
  something else — created one silently, and this stayed green. Different
  titles are the only version of this that tests the rule.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat` — the
  two-way agent chat someone lands in after signup. Distinct from the intake
  interview on `/build/workspace`, which runs earlier and stops at derived
  rules.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :chat_llm, %{
      tool_calls: [
        %{
          name: "create_story",
          arguments: %{
            "title" => "Bookings show up on a calendar",
            "story" =>
              "As a salon owner, I want to see today's bookings on a calendar, so that I know who is coming in."
          }
        },
        %{
          name: "create_story",
          arguments: %{
            "title" => "Stylists get a text when someone books",
            "story" =>
              "As a stylist, I want a text when a client books with me, so that I do not have to watch the calendar."
          }
        }
      ],
      chunks_after_tool: ["Here is the story I captured."]
    })

    on_exit(fn -> Application.delete_env(:code_my_spec, :chat_llm) end)
    :ok
  end

  spex "The conversation refuses to create more than one story" do
    scenario "A second story is refused, not silently added" do
      given_ "the conversation has already created Sam's story", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "the model attempts to create another", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the second is refused, and says so", context do
        assert context.html =~ "Bookings show up on a calendar",
               "anchor: the first story should still be here"

        refute has_element?(context.chat, "[data-test='story-card']:nth-of-type(2)"),
               "expected the second create to be refused"

        # Refused *and* answered. The model has to be told a story already
        # exists, or it has no way to recover except by trying again — which is
        # the loop the cap exists to stop.
        assert context.html =~ "already produced a story",
               "expected the refusal to come back as the tool result the model reads"

        # Not "the title is absent from the page" — the refused call renders its
        # own arguments now, so the title it *asked* for legitimately appears
        # there. Whether a story was created is a question about the board, and
        # the board is checked below: one card, and no second title on it.
        refute has_element?(context.chat, "[data-test='story-card'][data-story-title]"),
               "a refused create must not produce a second story card"

        {:ok, context}
      end

      then_ "Sam still has exactly one story", context do
        {:ok, _stories_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        # Counted through the page, not the database: a then_ observes the
        # public surface. Story cards are the stream children of #stories —
        # counting title occurrences would not work, because the index renders
        # a title in more than one place per story.
        assert html =~ "Bookings show up on a calendar",
               "anchor: the one story should be on the page"

        cards =
          html
          |> Floki.parse_document!()
          |> Floki.find("#stories > div")

        assert length(cards) == 1,
               "expected exactly one story card on the page, got #{length(cards)}"

        refute html =~ "Stylists get a text when someone books",
               "the refused story reached the board anyway"

        {:ok, context}
      end
    end
  end
end
