defmodule CodeMySpecSpex.WorkingCopyHelpers do
  @moduledoc """
  The two surfaces story 1019's criteria establish state through.

  Here rather than in each criterion because there are eight of them and they
  need the same two things. A helper copied eight times is a parsing bug fixed
  seven times and missed once — which is how `response_field/2` ended up in
  `TaskResponseHelpers` after being written five times in story 1018.

  Neither of these is a fixture reaching behind the app. A working copy exists
  because a harness joined for it, and an agent is running because a harness said
  so; both are the real channels, driven the way the harness drives them.
  """

  import ExUnit.Assertions
  import Phoenix.ChannelTest

  alias CodeMySpecWeb.HarnessChannel
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  Bring a working copy into existence by joining for it.

  `Harnesses.issue/3` mints an id on join when the payload carries none, which
  is why a checkout and a harness are the same thing. Returns the join reply,
  which carries the minted `harness_id`.
  """
  @spec join_working_copy(map(), String.t(), String.t()) :: map()
  def join_working_copy(context, root, label) do
    {:ok, reply, _socket} =
      UserSocket
      |> socket("spex-1019-#{label}", %{scope: context.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{context.project.id}",
        %{"harness_id" => nil, "root" => root, "label" => label}
      )

    reply
  end

  @doc """
  Report the set of agents a harness is running.

  The whole set every time, because that is the contract: anything absent from a
  report is no longer running. Passing `[]` is how a criterion says an agent went
  away without simulating a death.
  """
  @spec report_agents(map(), [map()]) :: map()
  def report_agents(context, agents) do
    {:ok, _reply, socket} =
      UserSocket
      |> socket("spex-1019-report", %{scope: context.scope})
      |> subscribe_and_join(
        HarnessChannel,
        "harness:#{context.scope.active_account_id}",
        %{}
      )

    ref = Phoenix.ChannelTest.push(socket, "agents_running", %{"agents" => agents})

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, payload: payload} -> payload
    after
      1_000 -> flunk("the harness channel never acknowledged agents_running")
    end
  end

  @doc "One Pi agent on a copy, as a harness would report it."
  @spec pi_agent(String.t()) :: map()
  def pi_agent(root),
    do: %{"working_copy" => root, "provider" => "zai", "engine" => "pi"}

  @doc "One Claude Code agent on a copy, as a harness would report it."
  @spec claude_agent(String.t()) :: map()
  def claude_agent(root),
    do: %{"working_copy" => root, "provider" => "anthropic", "engine" => "claude_code"}
end
