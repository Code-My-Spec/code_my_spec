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
        copy = join_working_copy(context, "/tmp/spex-1019-claude-only", "claude checkout")
        report_agents(context, [claude_agent(copy.working_copy_id, "/tmp/spex-1019-claude-only")])

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :live, live)}
      end

      when_ "an engineer opens that copy", context do
        {:ok, copy, html} =
          context.live
          |> element(
            "[data-test='working-copy'][data-root='/tmp/spex-1019-claude-only'] [data-test='open-working-copy']"
          )
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, context |> Map.put(:copy, copy) |> Map.put(:html, html)}
      end

      then_ "they can read what it is and when it was last heard from", context do
        assert has_element?(context.copy, "[data-test='agent'][data-engine='claude_code']"),
               "a Claude Code agent that cannot be talked to still has to be " <>
                 "watchable, or there is no reason for it to be here at all"

        assert has_element?(context.copy, "[data-test='agent-liveness-since']"),
               "the row says the agent is there and not when it was last heard " <>
                 "from, which is the only fact hooks give us. Without the time, " <>
                 "an agent that died this morning reads the same as one mid-thought."

        {:ok, context}
      end

      then_ "and there is nothing offering to take them somewhere to reply", context do
        refute has_element?(context.copy, "[data-test='open-agent-chat']"),
               "a chat link on a Claude-Code-only copy leads to a box that accepts " <>
                 "text and drops it — there is no lane to route a user_message to. " <>
                 "An offer that silently does nothing is worse than an absent one: " <>
                 "the person believes they redirected the agent, and finds out " <>
                 "otherwise when the work comes back wrong."

        assert has_element?(context.copy, "[data-test='no-agent-chat']"),
               "the copy withholds the chat and says nothing about why, which " <>
                 "reads as the page being broken rather than as a decision."

        {:ok, context}
      end
    end
  end
end
