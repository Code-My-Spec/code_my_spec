defmodule CodeMySpecSpex.Story1019.Criterion2836Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2836 — An agent nobody is running is not on the list as running.

  Rule: The page never shows as running something that has stopped reporting.

  The page's claim about what is running has to come from the harness's claim,
  not from what the server remembers asking for. `Agents.record_reported/2`
  already marks anything absent from a report as stopped; this asserts the page
  reflects it rather than reading a stale row.

  Distinct from 2831, which is about a *Pi* agent's presence disappearing the
  moment its process does. This one is about the whole box going quiet — a
  harness that stopped reporting, for any engine and any reason — and it holds
  for Claude Code too, which has no presence to lose.

  Why it is worth a criterion: `Workspaces.Runner.Local` documents the same class
  of failure against itself at `local.ex:36-44`, where a supervisor restart
  orphans a process while the row still points at it. A row claiming an agent is
  working is precisely how nobody notices one that is not — and on a subscription
  it keeps spending while nobody looks.
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

  spex "What the page claims is what the harness said" do
    scenario "An agent nobody is running is not on the list as running" do
      given_ "an agent shown as running on a copy", context do
        join_working_copy(context, "/tmp/spex-1019-quiet", "quiet checkout")
        report_agents(context, [claude_agent("/tmp/spex-1019-quiet")])

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert render(live) =~ ~r/running|last (heard|seen|reported)/i,
               "the agent has to be shown as running before it stopping means anything"

        {:ok, Map.put(context, :live, live)}
      end

      when_ "the harness stops reporting it", context do
        report_agents(context, [])

        {:ok, context}
      end

      then_ "the page stops showing it as running", context do
        row =
          context.live
          |> element("[data-test='working-copy'][data-root='/tmp/spex-1019-quiet']")
          |> render()

        refute row =~ ~r/\brunning\b/i,
               "the harness stopped reporting this agent and the page still calls " <>
                 "it running. That is the row that keeps somebody from noticing an " <>
                 "agent spending a subscription with nothing watching it. " <>
                 "Got: #{row}"

        {:ok, context}
      end

      then_ "and says so rather than going blank", context do
        row =
          context.live
          |> element("[data-test='working-copy'][data-root='/tmp/spex-1019-quiet']")
          |> render()

        assert row =~ ~r/no agent|idle|nothing running|stopped/i,
               "the row no longer claims the agent is running and now says nothing " <>
                 "at all, which reads as a rendering failure rather than as an " <>
                 "answer. Got: #{row}"

        {:ok, context}
      end
    end
  end
end
