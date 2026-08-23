defmodule CodeMySpecSpex.Story1019.Criterion2832Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2832 — Both checkouts are there, one of them idle.

  Rule: Every working copy on the project is listed, including the ones running
  nothing.

  A working copy exists because a harness joined for it — `Harnesses.issue/3`
  mints one id per checkout on join, which is why "harness id" and "working copy
  id" are the same thing. So the page's list is the set of harnesses, not the set
  of agents, and a copy with nothing running on it is a row.

  Listing only the busy ones would be the easier query and the wrong answer: a
  copy that is missing reads as a copy that does not exist, and the question this
  page answers is "what have I got", not "what is busy". On this project that is
  this checkout and the QA checkout, and the QA one is idle most of the time.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A project's working copies are all of them" do
    scenario "Both checkouts are there, one of them idle" do
      given_ "two working copies of the project, one with an agent and one without",
             context do
        busy = join_working_copy(context, "/tmp/spex-1019-busy", "busy checkout")
        idle = join_working_copy(context, "/tmp/spex-1019-idle", "idle checkout")

        # Only the first one is running anything.
        report_agents(context, [pi_agent(busy.harness_id, "/tmp/spex-1019-busy")])

        {:ok, context |> Map.put(:busy, busy) |> Map.put(:idle, idle)}
      end

      when_ "an engineer opens the page", context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "both are listed", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-root='/tmp/spex-1019-busy']"
               ),
               "the copy with an agent on it is missing from the list"

        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-root='/tmp/spex-1019-idle']"
               ),
               "the idle copy is missing. Listing only what is busy answers a " <>
                 "different question than the one this page exists for — a copy " <>
                 "that is absent reads as a copy that does not exist."

        {:ok, context}
      end

      then_ "the idle one says it is idle rather than saying nothing", context do
        idle =
          context.live
          |> element("[data-test='working-copy'][data-root='/tmp/spex-1019-idle']")
          |> render()

        assert idle =~ ~r/no agent|idle|nothing running/i,
               "the idle copy is on the list but says nothing about being idle, " <>
                 "which reads as a row that failed to load rather than one with " <>
                 "nothing to report. Got: #{idle}"

        {:ok, context}
      end
    end
  end
end
