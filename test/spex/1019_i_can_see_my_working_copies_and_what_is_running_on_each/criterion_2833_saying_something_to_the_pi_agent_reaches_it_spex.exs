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
  transport. What it asserts is that the engineer does not have to go somewhere
  else to do it — a page that shows you an agent and then sends you to a
  different screen to answer it has not connected anything.

  The conversation is keyed `pi:<working_copy>`, which is what makes a transcript
  reachable from a copy at all. That was not true a day ago: `start_agent` keyed
  it `agent:<id>` and the lane keyed it by copy, so an agent's own turns landed
  on a different conversation than the one representing it (18f50c87).
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
        join_working_copy(context, "/tmp/spex-1019-talkable", "talkable checkout")
        report_agents(context, [pi_agent("/tmp/spex-1019-talkable")])

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :live, live)}
      end

      when_ "an engineer opens its transcript and sends it a message", context do
        context.live
        |> element("[data-test='working-copy'][data-root='/tmp/spex-1019-talkable'] [data-test='open-transcript']")
        |> render_click()

        html =
          context.live
          |> form("[data-test='agent-reply']", %{"message" => "stop and summarise"})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the message appears in the transcript it was sent from", context do
        assert context.html =~ "stop and summarise",
               "the message was sent and is not in the transcript. An operator who " <>
                 "cannot see what they just said has no way to tell whether it went."

        {:ok, context}
      end

      then_ "and they did not have to find another surface to do it on", context do
        assert has_element?(context.live, "[data-test='agent-reply']"),
               "replying moved the engineer off this page. Showing an agent and " <>
                 "then sending someone elsewhere to answer it has not connected " <>
                 "the two things, it has listed them."

        {:ok, context}
      end
    end
  end
end
