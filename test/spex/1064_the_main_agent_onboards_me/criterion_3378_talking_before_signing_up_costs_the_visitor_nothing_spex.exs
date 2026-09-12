defmodule CodeMySpecSpex.Story1064.Criterion3378Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3378 — A visitor can keep talking to the agent without being asked
  for a model key or for an account.

  ## What this is really guarding

  The agent costs money to run, and the cheapest way to stop an anonymous
  visitor costing anything is to ask them for a key, or to make them sign up
  first. Either is a reasonable engineering decision and both end the story:
  somebody who has not decided to use the product yet will not go and get an
  API key to continue a conversation.

  So this is a spec against a plausible future rather than against a present
  bug, which is what makes it worth writing down. It stays green for as long as
  nobody puts a gate in, and goes red the moment somebody does — which is when
  the decision deserves to be made deliberately instead of arrived at.

  ## Carrying on, not arriving

  The criterion says "when they carry on talking", so one turn is not the test.
  A gate placed at the second turn, or after shaping produces something worth
  paying for, is exactly where a reasonable person would put it — so the visitor
  here describes an idea, answers the shaping questions, and only then is the
  page checked.

  ## Why the assertion is on the rendered page

  Not on config, and not on whether a key exists. What the criterion promises is
  about the visitor's experience: they are never *asked*. A system that quietly
  falls back to a shared key and never mentions it satisfies this; a system with
  a key configured that still demands one does not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  # Ways of asking, rather than one phrasing. A gate that said "add your
  # Anthropic key" would slip past a check for "API key".
  @asks_for_a_key ["api key", "api_key", "anthropic key", "openai key", "model key", "byok"]
  @asks_to_sign_up ["sign up to continue", "create an account to continue", "log in to continue"]

  spex "somebody is talking to the agent before they have an account" do
    scenario "Talking before signing up costs the visitor nothing" do
      given_ "somebody is talking to the agent before they have an account", context do
        conn = Phoenix.ConnTest.build_conn()
        {:ok, live, _html} = live(conn, "/build")

        describe_idea(live, "a booking tool for a two-chair barbershop")

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "they carry on talking", context do
        html = answer_shaping_questions(context.live)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they are never asked for a model key", context do
        page = String.downcase(context.html)

        for ask <- @asks_for_a_key do
          refute page =~ ask,
                 """
                 The visitor is being asked for a model key (#{ask}) to carry on.
                 Somebody who has not decided to use the product yet will not go and
                 get an API key to continue a conversation.
                 """
        end

        {:ok, context}
      end

      and_ "they are never asked to sign up in order to continue", context do
        page = String.downcase(context.html)

        # The anchor. Without it every refute above would pass on an empty page,
        # and an empty page is one of the ways this could break.
        assert has_element?(context.live, "[data-test='intake-transcript']"),
               "there is no conversation on the page, so nothing here proves anything"

        for ask <- @asks_to_sign_up do
          refute page =~ ask,
                 """
                 The visitor is being made to sign up to carry on talking. Signing up
                 is where the conversation leads, not its entry fee.
                 """
        end

        {:ok, context}
      end
    end
  end
end
