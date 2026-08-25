defmodule CodeMySpecSpex.Story963.Criterion2921Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2921 — The main agent hands over rather than designing.

  Rule: The main agent shapes stories and epics; the detailed design of each story happens elsewhere.

  The PM drew this line himself: "the three amigos process will for sure
  happen inside the individual story work, so the main agent won't be doing
  three amigos. It'll get you your six stories and slap those in an epic and
  then assign those to a working copy, and an agent will do the three amigos."

  It corrects an earlier note that had the main agent driving the Three Amigos
  screen.

  ## What a spex can assert here, and what it cannot

  This criterion is about what the agent *says*. A spex drives surfaces, not a
  model, so it cannot assert prose — and a check dressed up to look as though
  it does would go green while the thing the criterion cares about was wrong.

  So this asserts that a story the main agent has grouped into an epic still owes its own Three Amigos. Whether the agent refrains from attempting it is left to QA, where a person reads
  what the agent actually said.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

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

  spex "The main agent shapes stories and epics; the detailed design of each story happens elsewhere" do
    scenario "The main agent hands over rather than designing" do
      given_ "I have described what I want built", context do
        copy = CodeMySpec.TempFile.dir("spex_2921")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, context}
      end

      when_ "the main agent has turned that into stories grouped in an epic", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "its part is done", context do
        assert context.html =~ "data-test=\"main-agent\"",
               "there is no main agent whose part could be done"

        {:ok, context}
      end

      then_ "and the detailed design of each story is not something it produced",
            context do
        refute context.html =~ "three-amigos",
               "the main agent's surface offers the Three Amigos session. That work " <>
                 "belongs to the agent in the working copy the epic was sent to, and " <>
                 "an agent that does it here is doing the detailed design it is " <>
                 "supposed to hand over."

        {:ok, context}
      end
    end
  end
end
