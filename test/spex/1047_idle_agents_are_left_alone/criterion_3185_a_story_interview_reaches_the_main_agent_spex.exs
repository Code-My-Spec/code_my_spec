defmodule CodeMySpecSpex.Story1047.Criterion3185Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3185 — A story interview reaches the main agent.

  The third separation this story makes. 3179 separates roles, 3184 separates
  checkouts, and this separates the main agent from the copies: shaping work —
  a project with no stories yet, needing the interview that produces them —
  belongs to the main agent, and the agents on the working copies cannot do it
  at all.

  It matters more than the other two because of who is left holding it. A
  shaping item that wakes the copies wakes agents that will read it, find no
  requirement they can act on, and stop — while the main agent, the one that
  could have done it, is told nothing and stays quiet. The work is reachable by
  exactly one agent and gets offered to every other one.

  ## Which interview

  There are two, and they belong to different agents. John: "the main agent
  does the initial story interview that gets the initial stories up, and then
  the product agent in the assigned working copy does the three amigos". So
  this is `stories_exist` — project-scoped, before there is a checkout to
  assign — and not `three_amigos_complete`, which is per story and product's.

  Read on the main agent's transcript, because that is where its menu arrives.
  An agent we run fires no hooks: `Agents.StopDecision` sends it the same menu
  `Hooks.Stop` would have put in a reply. This used to post `/api/hooks/stop`
  and read the response, which is the external agent's path — and the reply was
  `%{}` every time, because a session that is not in continuous mode is simply
  allowed to stop.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Shaping work reaches the main agent and nobody else" do
    scenario "A story interview reaches the main agent" do
      given_ "a project past kickoff whose only outstanding work is shaping", context do
        # Kickoff satisfies the project artifacts and stops short of stories —
        # "the caller is responsible for `stories_exist`" — so leaving it
        # alone is what puts the interview on the graph, and nothing else with
        # it. No component is synced, so the coding lane is empty.
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "the copy already synced once, so the graph knows what is outstanding",
             context do
        # A premise rather than a convenience, and it costs a wake to nobody
        # because no agent exists yet.
        #
        # Two things only a sync settles. `personas_complete` reads the
        # persona's `summary.md` and `sources.md` off the projection, so until
        # something scans the checkout it is unsatisfied — and it gates
        # `stories_exist`, so the interview is not on the graph at all. And
        # switching a copy on rings the bell itself (`set_copy_continuous/3`
        # calls `wake_roles/3`), rendering each role's menu from whatever the
        # graph holds at that instant.
        #
        # Together those mean the first switch-on of a never-synced project is
        # silent for every role, including the one whose work was waiting.
        # Filed as `a0780389`; it is not what this criterion is about, and a
        # scenario that left it implicit would be asserting routing against an
        # empty graph.
        {:ok, put_to_work(context)}
      end

      given_ "a main agent and a coding agent on a working copy", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        coding = Fixtures.running_agent(context.scope, role: "coding")

        {:ok,
         context
         |> Map.put(:main, main.id)
         |> Map.put(:coding, coding.id)
         |> Map.put(:main_before, heard_count(context, main.id))
         |> Map.put(:coding_before, heard_count(context, coding.id))}
      end

      when_ "the copy is switched on and the work is routed", context do
        {:ok, put_to_work(context)}
      end

      then_ "the main agent's menu names the story interview", context do
        said = latest(context, context.main)

        assert said =~ ~r/(interview|shape|story)/i,
               """
               The only work available is shaping work, and the main agent's
               menu does not mention it — so the one agent that can do it is
               not told it exists.

               got: #{inspect(said)}
               """

        {:ok, context}
      end

      then_ "and the agents on the working copies are sent nothing", context do
        refute_told_anything(
          context,
          context.coding,
          context.coding_before,
          """
          A working-copy agent was woken by shaping work it cannot do.

          It will read the graph, find no requirement it can act on, and stop.
          Meanwhile the main agent — the one that could have done it — is the
          one that was told nothing.
          """
        )

        {:ok, context}
      end
    end
  end
end
