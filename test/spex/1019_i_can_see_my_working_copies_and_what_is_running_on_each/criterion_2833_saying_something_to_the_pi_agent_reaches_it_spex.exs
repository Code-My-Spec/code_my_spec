defmodule CodeMySpecSpex.Story1019.Criterion2833Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2833 — Saying something to the Pi agent reaches it.

  Rule: A Pi agent can be talked to from here; a Claude Code agent can only be
  watched.

  This criterion is about one surface reaching the other, not about building a
  transport. What it asserts is that a copy leads to the conversation its agent
  is actually writing to — reachable in a click, and the *right* one.

  ## What the key is now

  It used to be `pi:<working_copy>`: one conversation per checkout, holding the
  whole team's turns, and that is what made it reachable from a copy. Story
  1024's criterion 2892 replaced that — a conversation belongs to the agent,
  because a copy runs several and their turns interleaving into one thread
  means following either is impossible and a reply cannot say who it is for.

  So the copy page lists a link per agent, and what has to be true is unchanged
  in substance: the link lands on that agent's own conversation and not on
  somebody else's. The mistake it guards against is the same one 18f50c87 was —
  a page opening *a* conversation rather than *this* one — and it is easier to
  make now, not harder.

  ## Why the reply is not on this page

  There is a dedicated agent chat, and it renders a transcript properly. A
  second transcript inlined on the working copy would be a worse copy of it and
  a second place to look for one conversation; the failure that produces is
  somebody reading the stale half. So the copy links out.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
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
        talkable_root = CodeMySpec.TempFile.dir("spex_2833_talkable")
        other_root = CodeMySpec.TempFile.dir("spex_2833_other")
        RealDisk.mkdir_p!(talkable_root)
        RealDisk.mkdir_p!(other_root)

        {talkable, socket} =
          join_working_copy_socket(context, talkable_root, "talkable checkout")

        other = join_working_copy(context, other_root, "the other checkout")

        report_agents(context, [
          pi_agent(talkable.working_copy_id, talkable_root),
          pi_agent(other.working_copy_id, other_root)
        ])

        # A real process for each, so a message sent from the page has somewhere
        # to land. Both, because the failure being guarded against is a link
        # that opens *a* conversation instead of *this* one, and with a single
        # agent on the project that mistake passes.
        talkable_agent = agent_on(context, talkable_root)
        other_agent = agent_on(context, other_root)

        start_agent_with_provider(talkable_agent.id, working_copy: talkable_root)
        start_agent_with_provider(other_agent.id, working_copy: other_root)

        # A line in each agent's own transcript, said the way a machine says it.
        # The transcript itself is the evidence, so a link that opened a
        # different one shows up as the line being missing rather than as an id
        # assertion that can pass on a truncated render.
        agent_stepped(socket, talkable_agent, "working on the talkable copy")
        agent_stepped(socket, other_agent, "working on the other copy")

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, context |> Map.put(:live, live) |> Map.put(:talkable_root, talkable_root)}
      end

      when_ "an engineer opens that copy and follows it to the agent chat", context do
        {:ok, copy, _html} =
          context.live
          |> element(
            "[data-test='working-copy'][data-root='#{context.talkable_root}'] [data-test='open-working-copy']"
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

      then_ "and the transcript is that agent's own, not another one", context do
        assert context.html =~ "working on the talkable copy",
               "the copy linked to a conversation that is not the one its agent " <>
                 "writes to. The reply is delivered, to nobody — which is 18f50c87 " <>
                 "happening again through the link instead of through the key."

        refute context.html =~ "working on the other copy",
               "this copy's page opened a transcript holding another agent's turns. " <>
                 "Two agents reading as one thread is how an operator answers the " <>
                 "one they were not looking at."

        {:ok, context}
      end
    end
  end

  defp agent_on(context, root) do
    context.scope
    |> Fixtures.list_agents()
    |> Enum.find(&(&1.working_copy == root))
  end

  # One step, on the channel a machine reports steps on, waited out before
  # anything is asked of the record.
  defp agent_stepped(socket, agent, text) do
    ref =
      Phoenix.ChannelTest.push(socket, "agent_turn_event", %{
        "agent_id" => agent.id,
        "event" => %{"kind" => "assistant", "text" => text}
      })

    # `assert_reply/2` waits 100ms. That is the reply to a channel push on a
    # machine running several agents and two analyzer suites, and it is not
    # enough: this went red with the reply absent and an unrelated Swoosh email
    # the only thing in the mailbox, while passing alone and in its own story's
    # suite at a lower load. Same shape as story 998's `render_async/1` calls,
    # and the same 5s the rest of the suite settled on.
    Phoenix.ChannelTest.assert_reply(ref, :ok, %{}, 5_000)
  end
end
