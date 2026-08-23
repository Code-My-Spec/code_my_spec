defmodule CodeMySpecSpex.Story1019.Criterion2830Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2830 — A live Pi agent and a quiet Claude one do not look alike.

  Rule: Liveness is shown for what it is: a Pi agent is present or not, a Claude
  Code agent was last heard from at a time.

  Two different facts, and the page has to stop pretending they are one.

  A Pi lane is tracked in Presence on the harness channel — joined for exactly as
  long as its process lives, which is why story 704 replaced a polled
  subagent-TTL registry with it. Its liveness is a fact about right now.

  A Claude Code agent has no channel to be present on. It reports over HTTP
  hooks: `SessionStart` writes a row and `touch_session/2` bumps a timestamp.
  What is known is when it last did something, which is recency. An agent that
  died five minutes ago and one mid-thought are the same row.

  Putting both under one "Connected" badge invents a fact for half of them, and
  the half it invents for is the half that can quietly be dead.
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

  spex "Liveness is not one fact" do
    scenario "A live Pi agent and a quiet Claude one do not look alike" do
      given_ "a Pi agent on one copy and a Claude Code agent on another", context do
        join_working_copy(context, "/tmp/spex-1019-pi", "pi checkout")
        join_working_copy(context, "/tmp/spex-1019-claude", "claude checkout")

        report_agents(context, [
          pi_agent("/tmp/spex-1019-pi"),
          claude_agent("/tmp/spex-1019-claude")
        ])

        {:ok, context}
      end

      when_ "an engineer opens the page", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :live, live)}
      end

      then_ "the Pi agent reads as present now", context do
        pi = row(context, "/tmp/spex-1019-pi")

        assert pi =~ ~r/present/i,
               "a Pi lane is joined for as long as it is alive, so its liveness is " <>
                 "a fact about now and should be stated as one. Got: #{pi}"

        {:ok, context}
      end

      then_ "the Claude Code agent reads as last heard from, with when", context do
        claude = row(context, "/tmp/spex-1019-claude")

        assert claude =~ ~r/last (heard|seen|reported)/i,
               "a Claude Code agent has no channel to be present on — only hook " <>
                 "timestamps — so the honest claim is recency. Got: #{claude}"

        {:ok, context}
      end

      then_ "neither is described in the other's terms", context do
        claude = row(context, "/tmp/spex-1019-claude")

        refute claude =~ ~r/\bpresent\b/i,
               "the Claude Code agent is described as present, which is a fact " <>
                 "nothing establishes. An agent that died five minutes ago and one " <>
                 "mid-thought produce the same timestamp, and calling that presence " <>
                 "is inventing the difference. Got: #{claude}"

        {:ok, context}
      end
    end
  end

  defp row(context, root) do
    context.live
    |> element("[data-test='working-copy'][data-root='#{root}']")
    |> render()
  end
end
