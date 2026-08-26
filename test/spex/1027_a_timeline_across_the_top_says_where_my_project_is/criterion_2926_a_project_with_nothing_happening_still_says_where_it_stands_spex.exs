defmodule CodeMySpecSpex.Story965.Criterion2926Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2926 — A project with nothing happening still says where it stands.

  Rule: Exactly one step is marked as where the project is now.

  The failure mode with teeth, because it is invisible. A project where nothing
  is in flight is the ordinary overnight state, and a timeline that marks no
  step then is indistinguishable from one that failed to load — same blank line,
  same absence of an indicator.

  Waiting is a place to be. The timeline says which step the project is waiting
  at, and story 964's node is the reason that matters: idle with unassigned work
  is exactly the state that wants somebody to act.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
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

  # The timeline rides the main agent's conversation, and there is no main agent
  # without somewhere to run it — `ensure_main_agent/1` refuses with
  # `:not_connected`. Same reason story 963's criteria connect one.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "Exactly one step is marked as where the project is now" do
    scenario "A project with nothing happening still says where it stands" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_timeline")}
      end

      given_ "a project where no work is in flight", context do
        # Nothing is started on a fresh project, which is the state. Asserted
        # rather than assumed, because a project with an agent running would be
        # testing the other case entirely.
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute html =~ "data-test=\"agent-chip\"",
               "an agent is running on this project, so nothing-in-flight is not the " <>
                 "premise and what follows would be about a busy project"

        {:ok, context}
      end

      when_ "I look at the timeline", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :html, html)}
      end

      then_ "a step is still marked as where the project is", context do
        current = Regex.scan(~r/data-test="timeline-step"[^>]*data-state="current"/, context.html)

        assert length(current) == 1,
               "an idle project marks no step, so the timeline looks exactly like one " <>
                 "that failed to load. Waiting is a place to be and the screen has to " <>
                 "say which place."

        {:ok, context}
      end

      then_ "and it does not read as broken", context do
        refute context.html =~ ~r/data-test="project-timeline"[^>]*data-state="error"/,
               "an idle project is reported as an error"

        # The anchor beside the refute, so an empty page cannot pass this block.
        # It has followed the header down as prose was cut: the two explanatory
        # sentences first, then the step's full title, and now the pill — which
        # is the last thing left that names where the project is, and the only
        # one that survives a glance.
        assert context.html =~ "data-test=\"current-step\"",
               "the timeline marks no current step, so the screen says nothing about " <>
                 "where the project is — which is indistinguishable from one that failed " <>
                 "to load"

        {:ok, context}
      end
    end
  end
end
