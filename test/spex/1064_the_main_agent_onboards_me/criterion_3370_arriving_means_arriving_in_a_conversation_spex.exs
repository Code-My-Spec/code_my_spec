defmodule CodeMySpecSpex.Story1064.Criterion3370Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3370 — Somebody with no account who arrives to get set up is in a
  conversation, not in front of a form they had to find.

  ## Which door "they land" means

  The criterion does not name one, and the two candidates differ. `/` is the
  marketing page — FAQ, meta tags, JSON-LD — and asserting a conversation there
  would be asserting the marketing site away, which no rule on this story asks
  for. `/build` is the door for somebody who has come to get set up, and it is
  the one `POST /build` from the home page leads to.

  So this drives `/build`. If the intent was that the *front* page opens a
  conversation, this spex is aimed at the wrong door and should be pointed at
  `/` instead — flagging rather than guessing, because the two readings produce
  different products.

  ## Anonymous on purpose

  No `register_log_in_setup_account`. "No account and nothing set up" is the
  premise, so the visitor arrives on a bare `build_conn/0` and the anonymous
  plan token `CodeMySpecWeb.Plugs.IntakeSession` mints is the only identity in
  play.

  ## "Rather than in front of a form to find"

  The contrast is the assertion, and a page can satisfy the first half while
  failing it: a composer alone is still a form, just a prettier one. What makes
  it a conversation is that the agent has already spoken — there is a turn on
  the page before the visitor has done anything. So the positive assertion is
  the agent's own opening turn, not merely the presence of somewhere to type.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "somebody arrives with nothing set up" do
    scenario "Arriving means arriving in a conversation" do
      given_ "somebody arrives with no account and nothing set up", context do
        {:ok, Map.put(context, :conn, Phoenix.ConnTest.build_conn())}
      end

      when_ "they land", context do
        {:ok, live, html} = live(context.conn, "/build")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "they are in a conversation with the agent", context do
        assert has_element?(context.live, "[data-test='intake-transcript']"),
               "there is no conversation on the page at all"

        assert has_element?(context.live, "[data-test='intake-said'][data-from='agent']"),
               """
               The agent has not said anything. A page with somewhere to type and
               nobody talking is a form, which is the thing this criterion
               contrasts against — the conversation is what makes it not one.
               """

        {:ok, context}
      end

      and_ "rather than in front of a form to find", context do
        refute context.html =~ "Sign up",
               """
               The visitor is being asked to make an account before they can say
               anything. Arriving to get set up should start the conversation, not
               put registration in front of it.
               """

        {:ok, context}
      end
    end
  end
end
