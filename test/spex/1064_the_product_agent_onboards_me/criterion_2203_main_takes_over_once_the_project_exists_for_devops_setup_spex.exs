defmodule CodeMySpecSpex.Story1064.Criterion2203Spex do
  @moduledoc """
  Story 1064 — The product agent onboards me
  Criterion 2203 — Once the onboarding questions are answered and the project
  exists, the project's own main agent takes over the conversation, and it
  starts on the project's devops setup.

  ## Beyond "onboarding ends somewhere"

  Criterion 1327 in this story already drives confirming the plan through to
  a page with a project on it, and already asserts the visitor is "in front
  of the agent that runs it" — but, written before John's 2026-10-13 call
  that the product agent runs onboarding until the project exists, it asserts
  that destination is still an intake-style page (`intake-transcript`,
  `form[phx-submit=answer]`). This criterion is the more specific, later
  claim that supersedes that assumption: the page is the project's own
  agent-conversation, and the agent on it is identifiably *main*, not a
  continuation of intake. This spex does not touch 1327 — a stale assertion
  there is 1327's own question to settle, not this one's to silence.

  ## What stands for "starts on devops setup"

  Nothing on the agent-conversation page marks a devops-setup state the way
  `main-agent` marks the agent's identity — `main_summary/1`'s own comment
  says the agent is "what will write" the project's status in prose, by
  design, rather than a status assembled from rows. So the only honest
  surface for "starts on devops setup" is the agent's own first words, and
  this checks for them loosely (case-insensitively, on "devops" or "setup")
  rather than asserting exact copy no implementation has been held to yet.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  setup do
    stub_local_trial()
    :ok
  end

  spex "the onboarding questions are answered and the project exists", criterion: 2203 do
    scenario "Main takes over once the project exists, for devops setup" do
      given_ "the onboarding questions are answered and the project exists", context do
        conn = get(context.conn, "/build")
        {:ok, live, _html} = live(conn)

        describe_idea(live, "a booking tool for a two-chair barbershop")
        answer_shaping_questions(live)

        destination = confirm_plan(live, %{location: "local"})
        {:ok, confirmed, _html} = live(conn, destination)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:confirmed, confirmed)}
      end

      when_ "onboarding finishes", context do
        confirm_payment(context.confirmed)
        {:ok, context}
      end

      then_ "the project's main agent takes over the conversation", context do
        assert has_element?(context.confirmed, "[data-test='main-agent']"),
               """
               The agent on this page is not identifiable as the project's main
               agent. Onboarding finishing has to hand the conversation to the
               agent that runs the project, not leave the visitor talking to
               whatever was asking the onboarding questions.
               """

        {:ok, context}
      end

      and_ "it starts on the project's devops setup", context do
        html = render(context.confirmed)

        assert html =~ ~r/devops|setup/i,
               """
               Nothing on the page the visitor landed on says anything about
               devops or setup. Taking over silently is indistinguishable from
               not having anything to do yet.
               """

        {:ok, context}
      end
    end
  end
end
