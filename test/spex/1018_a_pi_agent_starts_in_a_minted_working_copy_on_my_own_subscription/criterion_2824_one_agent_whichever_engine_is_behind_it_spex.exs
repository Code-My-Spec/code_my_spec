defmodule CodeMySpecSpex.Story1018.Criterion2824Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2824 — One agent, whichever engine is behind it.

  Rule: A started Pi agent reports to the same places a Claude Code agent does.

  This is the criterion the story is worth doing for, and the surface it names
  already exists. `CodeMySpecWeb.HarnessChannel` is the user plane: the local
  app's proxy joins `harness:<account_id>`, relays each lane's `agent_message`
  up, and the channel persists it with `Conversations.add_agent_message/4` onto
  the conversation for that session. Claude Code's turns arrive that way today.

  So the spec drives that channel rather than anything Pi-specific, which is
  exactly what is being asserted: if a Pi agent needed its own path to become
  visible, there would be two surfaces to watch and no single answer to what is
  running on this project. Needing no new path is the criterion passing.

  ## Why the session id carries the working copy

  `external_id` is `pi:<cwd>` — the Pi launcher's own convention, which
  `CodeMySpecLocalWeb.HarnessSocket` parses back into a project. The index
  renders it as `data-session`, so attributing a session to a working copy costs
  nothing extra and is readable from the page. One project can have several
  copies with an agent each, and a session naming no copy cannot be told from
  the others.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecWeb.HarnessChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel runs in its own process, and an owner-only connection is
    # invisible to it.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One place to watch agents work" do
    scenario "One agent, whichever engine is behind it" do
      given_ "a harness on the account, serving this working copy", context do
        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_spex_2824", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessChannel,
            "harness:#{context.scope.active_account_id}",
            %{}
          )

        {:ok, Map.put(context, :socket, socket)}
      end

      when_ "a Pi agent on that copy reports what it is doing", context do
        # Qualified: `Plug.Conn.push/3` is imported here too, and it wins.
        Phoenix.ChannelTest.push(context.socket, "agent_message", %{
          "external_id" => "pi:#{context.scope.cwd}",
          "project_id" => context.project.id,
          "role" => "develop",
          "kind" => "text",
          "text" => "Working the requirement graph."
        })

        # `push/3` is a cast, and the assertions below read what it produced. A
        # round trip on the same channel process is ordered behind it, which
        # waits for the work rather than for a clock.
        _ = :sys.get_state(context.socket.channel_pid)

        {:ok, context}
      end

      then_ "it appears where a Claude Code agent on the same copy would appear",
            context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        assert has_element?(live, "[data-test='agent-conversation-row']"),
               "a reporting Pi agent produced no session on the surface where agents " <>
                 "are watched. A second reporting path means two surfaces and no " <>
                 "single answer to what is running on this project."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "its work is attributed to the working copy it is on", context do
        assert context.html =~ context.scope.cwd,
               "the agent's session is not attributed to a working copy on the page " <>
                 "where agents are watched. One project can have several copies with " <>
                 "an agent each, and a session that names no copy cannot be told from " <>
                 "the others. Every other harness surface is keyed this way."

        {:ok, context}
      end
    end
  end
end
