defmodule CodeMySpecSpex.Story1019.Criterion2833Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2833 — Saying something to the Pi agent reaches it.

  Rule: A Pi agent can be talked to from here; a Claude Code agent can only be
  watched.

  The path already exists in both directions. Up: a lane pushes `agent_message`,
  the local proxy relays it, and `CodeMySpecWeb.HarnessChannel` persists it onto
  the conversation for that working copy. Down: an operator reply lands on the
  conversation topic and the channel pushes it to the harness as `user_message`,
  tagged with the session's `external_id`, and the proxy routes it to the lane.

  So this criterion is about one surface reaching the other, not about building a
  transport. What it asserts is that a copy leads to the conversation its agents
  are actually writing to — reachable in a click, and the *right* one.

  ## Why the reply is not on this page

  There is a dedicated agent chat, and it renders a transcript properly. A second
  transcript inlined on the working copy would be a worse copy of it and a second
  place to look for one conversation; the failure that produces is somebody
  reading the stale half. So the copy links out, and what has to be true is that
  the link lands on that copy's own conversation.

  The conversation is keyed `pi:<working_copy>`, which is what makes it reachable
  from a copy at all. That was not true a day ago: `start_agent` keyed it
  `agent:<id>` and the lane keyed it by copy, so an agent's own turns landed on a
  different conversation than the one representing it (18f50c87). That is exactly
  the mistake the last step here is written to catch.
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

  spex "A Pi agent can be answered" do
    scenario "Saying something to the Pi agent reaches it" do
      given_ "a Pi agent working on a copy", context do
        talkable = join_working_copy(context, "/tmp/spex-1019-talkable", "talkable checkout")
        other = join_working_copy(context, "/tmp/spex-1019-other", "the other checkout")

        report_agents(context, [
          pi_agent(talkable.working_copy_id, "/tmp/spex-1019-talkable"),
          pi_agent(other.working_copy_id, "/tmp/spex-1019-other")
        ])

        # A line in each copy's own transcript, said the way a lane says it.
        # Two copies rather than one because the failure being guarded against
        # is a link that opens *a* conversation instead of *this* one, and with
        # a single conversation on the project that mistake passes.
        agent_says(context, "/tmp/spex-1019-talkable", "working on the talkable copy")
        agent_says(context, "/tmp/spex-1019-other", "working on the other copy")

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :live, live)}
      end

      when_ "an engineer opens that copy and follows it to the agent chat", context do
        {:ok, copy, _html} =
          context.live
          |> element(
            "[data-test='working-copy'][data-root='/tmp/spex-1019-talkable'] [data-test='open-working-copy']"
          )
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, chat, _html} =
          copy
          |> element("[data-test='open-agent-chat']")
          |> render_click()
          |> follow_redirect(context.conn)

        chat
        |> form("[data-test='agent-message-form']", %{"message" => "stop and summarise"})
        |> render_submit()

        # Read after the submit, not the submit's own return. The message is
        # persisted and broadcast inside the event, so it arrives at this
        # LiveView as a `handle_info` that has not run yet when `render_submit`
        # returns. `render/1` is a call, so it queues behind that message and
        # the ordering is deterministic — no waiting involved.
        {:ok, context |> Map.put(:chat, chat) |> Map.put(:html, render(chat))}
      end

      then_ "the message reaches the agent and appears in the transcript", context do
        assert context.html =~ "stop and summarise",
               "the message was sent and is not in the transcript. An operator who " <>
                 "cannot see what they just said has no way to tell whether it went."

        {:ok, context}
      end

      then_ "and the transcript is that copy's own, not another one", context do
        assert context.html =~ "working on the talkable copy",
               "the copy linked to a conversation that is not the one its agents " <>
                 "write to. The reply is delivered, to nobody: a lane pushes to " <>
                 "`pi:<working_copy>` and this landed somewhere else, which is " <>
                 "18f50c87 happening again through the link instead of through the key."

        refute context.html =~ "working on the other copy",
               "this copy's page opened a transcript holding another copy's turns. " <>
                 "Two checkouts reading as one thread is how an operator answers " <>
                 "the agent they were not looking at."

        {:ok, context}
      end
    end
  end
end
