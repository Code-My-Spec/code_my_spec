defmodule CodeMySpecSpex.Story1019.Criterion2834Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2834 — A Claude Code agent offers no box to type in.

  Rule: A Pi agent can be talked to from here; a Claude Code agent can only be
  watched.

  The other half, and the one that has to be got right rather than left to
  chance. A Claude Code agent takes its instructions from Claude Code. There is
  no lane to route a `user_message` to, so a reply box on that row is a box that
  accepts text and drops it.

  A control that silently does nothing is worse than an absent one. The person
  typing believes they have redirected an agent, and the agent carries on doing
  what it was doing — which they will not discover until the work comes back
  wrong.

  Both engines render on the same page from the same row, so the difference is
  one field deciding one affordance. That is exactly the kind of thing that gets
  implemented as "render the form always, ignore it sometimes".
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

  spex "A Claude Code agent is watched, not driven" do
    scenario "A Claude Code agent offers no box to type in" do
      given_ "a Claude Code agent working on a copy", context do
        join_working_copy(context, "/tmp/spex-1019-claude-only", "claude checkout")
        report_agents(context, [claude_agent("/tmp/spex-1019-claude-only")])

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :live, live)}
      end

      when_ "an engineer opens its transcript", context do
        html =
          context.live
          |> element("[data-test='working-copy'][data-root='/tmp/spex-1019-claude-only'] [data-test='open-transcript']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they can read what it has done", context do
        assert has_element?(context.live, "[data-test='agent-transcript']"),
               "a Claude Code agent that cannot be talked to still has to be " <>
                 "watchable, or there is no reason for its row to be here at all"

        {:ok, context}
      end

      then_ "and there is nothing inviting them to reply", context do
        refute has_element?(context.live, "[data-test='agent-reply']"),
               "a reply box on a Claude Code agent accepts text and drops it — " <>
                 "there is no lane to route a user_message to. A control that " <>
                 "silently does nothing is worse than an absent one: the person " <>
                 "believes they redirected the agent, and finds out otherwise when " <>
                 "the work comes back wrong."

        {:ok, context}
      end
    end
  end
end
