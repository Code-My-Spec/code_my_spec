defmodule CodeMySpecSpex.Story1064.Criterion2202Spex do
  @moduledoc """
  Story 1064 — The product agent onboards me
  Criterion 2202 — Whoever asks the onboarding questions and fills in the form
  is identifiably the product agent, and it is the same product agent before
  and after the visitor signs up.

  ## Which arrival this spex drives

  The criterion's Given admits two doors — "from the web or from desktop
  setup" — and a scenario drives one user action, not two. This drives the
  web door (`/build`, anonymous), the same door criteria 1321/1322/1324 in
  this story already drive. The desktop door's half of this claim — that
  setup hands off into the *same* onboarding conversation rather than a
  different one — is what criteria 2200 and 2201 already establish; a second
  scenario here would only re-assert that.

  ## How "identifiably the product agent" is checked

  Nothing on the intake page currently says which role is speaking — there is
  only ever one voice, so nothing has needed to say so. `ChatComponents`
  already carries the vocabulary for this: `chat_message/1` takes a `label`
  that becomes `data-agent-role` on the rendered turn (the same attribute
  `turn/1`, one layer up, sets from `message.agent_role`), and
  `CodeMySpec.Agents.RoleProfile` already lists `:product` as a role. Intake
  wraps `chat_message/1` in its own `data-test="intake-said"` marker without
  discarding the component underneath it (its own moduledoc says the wrapper
  is "kept" rather than switched to `chat_message`'s own markup), so this
  checks for the inner `data-agent-role="product"` rather than inventing a
  new attribute — the slot already exists; intake does not yet fill it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @description "a scheduling tool for a two-chair barbershop"

  spex "somebody arrives to get set up and the onboarding conversation starts",
    criterion: 2202 do
    scenario "The product agent asks the onboarding questions" do
      given_ "somebody arrives to get set up, from the web", context do
        conn = get(Phoenix.ConnTest.build_conn(), "/build")
        {:ok, live, _html} = live(conn)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "the onboarding conversation starts", context do
        context.live
        |> form("[data-test='intake-composer']", description: @description)
        |> render_submit()

        {:ok, context}
      end

      then_ "it is the product agent that asks the questions and fills in the form", context do
        assert has_element?(
                 context.live,
                 "[data-test='intake-said'][data-from='agent'] [data-test='message'][data-agent-role='product']"
               ),
               """
               The agent's turn does not say which role spoke it. There is a
               form to be filled in and a question in front of the visitor, but
               nothing identifies this as the product agent rather than any
               other voice that might one day speak in this conversation.
               """

        {:ok, context}
      end

      and_ "it is the same product agent before and after they sign up", context do
        conn = get(context.conn, "/users/register")
        {:ok, registration_live, _html} = live(conn)

        email = "barber-#{System.unique_integer([:positive])}@example.com"

        registration_live
        |> form("#registration_form", user: %{email: email})
        |> render_submit()

        assert_received {:email, %Swoosh.Email{text_body: body}}
        [link] = Regex.run(~r{/users/log-in/[^\s\]]+}, body)

        conn = get(conn, link)
        {:ok, live, _html} = live(conn, "/build")

        assert has_element?(
                 live,
                 "[data-test='intake-said'][data-from='agent'] [data-test='message'][data-agent-role='product']"
               ),
               """
               After signing up, the agent speaking in this conversation is no
               longer identifiable as the product agent — or is identifiable as
               something else. Signing up is not the moment the product agent
               hands off; onboarding has not finished, only an account now
               exists.
               """

        {:ok, context}
      end
    end
  end
end
