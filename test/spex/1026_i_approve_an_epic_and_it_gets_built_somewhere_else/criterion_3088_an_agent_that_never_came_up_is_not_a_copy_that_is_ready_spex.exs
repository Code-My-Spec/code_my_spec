defmodule CodeMySpecSpex.Story964.Criterion3088Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3088 — An agent that never came up is not a copy that is ready.

  Rule: A working copy comes up with its three agents, and the same three serve
  every epic it is given.

  The failure path, and it is not hypothetical — it is what happened on
  2026-09-04 and it is why this criterion exists.

  An agent was started on `broken_oaths/.claude/worktrees/war-epic`. Its
  `.cms_harness.json` was correct: right project, right deploy key, right server.
  The agent row said `starting`. The copy was never served, because a harness
  adopts a copy on its **first hook request** (`Projects.ensure_started/1`) and
  nothing in that directory had made one since the harness restarted an hour
  earlier. So the agent sat there, and the page showed a copy that looked fine.

  The only symptom anybody ever saw was a chat message failing to deliver:

      That message could not be delivered: nothing here is holding that working
      copy.

  That is the wrong place to find out. The person had already decided what to
  say, typed it, and sent it, and the system had had an hour to notice that a
  copy with an agent on it was not being served by anything.

  ## What this asserts, and what it deliberately does not

  It asserts the copy reports itself as not ready. It does not say *how* the
  copy comes to be served — whether starting an agent registers the copy,
  whether the harness enumerates roots at boot, or something else. That is the
  implementation's choice. What is not the implementation's choice is a copy
  that cannot run the work presenting as one that can.

  ## Red on purpose

  Nothing starts these agents yet (criterion 3087), so nothing can report that
  one failed to. Both halves land together.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Agents
  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A working copy comes up with its three agents" do
    scenario "An agent that never came up is not a copy that is ready" do
      given_ :synced_context_component

      given_ "an epic placed on a working copy", context do
        {:ok, EpicHelpers.dispatch_one(context, "The war epic", stories: 1)}
      end

      when_ "one of that copy's agents cannot be reached", context do
        # Stopping one is how a lane becomes unreachable through the ordinary
        # surface. What matters is that the copy has an agent it cannot run,
        # not which way it got there.
        [agent | _] = Agents.list_agents(context.scope)
        {:ok, _} = Agents.stop_agent(context.scope, agent.id)

        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the copy is reported as not ready", context do
        assert context.html =~ ~s(data-test="copy-not-ready"),
               "the copy still presents as able to do the work while one of the " <>
                 "agents it needs is not there. On 2026-09-04 that state lasted an " <>
                 "hour and surfaced only when somebody tried to talk to it."

        {:ok, context}
      end

      then_ "and I did not have to send a message to find out", context do
        refute context.html =~ ~s(data-test="copy-ready"),
               "the page says ready and not-ready at once. A person reads the " <>
                 "first thing they see and sends the message anyway, which is the " <>
                 "failure this criterion exists to end."

        {:ok, context}
      end
    end
  end
end
