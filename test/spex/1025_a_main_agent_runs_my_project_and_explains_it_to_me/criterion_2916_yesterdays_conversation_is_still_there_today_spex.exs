defmodule CodeMySpecSpex.Story963.Criterion2916Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2916 — Yesterday's conversation is still there today.

  Rule: The main agent picks up the same conversation every time, however long it has been.

  A project runs for months and the conversation about it is the record of why
  it looks the way it does. An agent that starts fresh each session makes the
  user the memory, which is exactly the job this agent was meant to take off
  them.

  Story 962 made the conversation durable — it is rows, and the page reads them
  back. What is missing is the other half: an agent that comes back *to* it,
  rather than a transcript nobody is holding.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The agent runs on a provider, and refusing without one is deliberate — an
  # agent started on a credential that does not resolve fails on its first
  # model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The main agent picks up the same conversation every time, however long it has been" do
    scenario "Yesterday's conversation is still there today" do
      given_ "I talked to the main agent yesterday about my project", context do
        context = given_a_main_checkout(context, "spex_2916")
        path = say_to_main_agent(context, "remember the pricing rule")

        {:ok, Map.put(context, :path, path)}
      end

      when_ "I open the project today", context do
        # Today's agent is a new process on a harness that has restarted since,
        # which is the ordinary case rather than the exceptional one: laptops
        # close. Brought back through the same restore the harness drives, so
        # what is asserted below is what a real morning produces.
        restart_harness(context.harness_socket)

        {:ok, _live, html} = live(context.conn, context.path)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the same conversation is there with everything we said", context do
        assert context.html =~ "remember the pricing rule",
               "what I said to the main agent is gone. A project's conversation is the " <>
                 "record of why it looks the way it does, and an agent that starts " <>
                 "fresh makes the user the memory."

        {:ok, context}
      end

      then_ "and I can carry on without repeating myself", context do
        assert context.html =~ "phx-submit=\"send_message\"",
               "there is nowhere to carry on from"

        # The page holding the history is not the agent holding it. A transcript
        # somebody can scroll and an agent that has to be told again are exactly
        # the state this criterion exists to rule out, and they look identical
        # from the page.
        assert agent_knows?(main_agent_id(context), "remember the pricing rule"),
               "the transcript came back and the agent did not. What I said is on the " <>
                 "screen and not in the agent, so carrying on means saying it again — " <>
                 "which is the user being the memory, with a page that hides it."

        {:ok, context}
      end
    end
  end
end
