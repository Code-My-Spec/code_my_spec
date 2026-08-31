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

  alias CodeMySpecSpex.Fixtures
  import Phoenix.ChannelTest

  alias CodeMySpecWeb.HarnessChannel
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  Bring a working copy into existence by joining for it.

  `WorkingCopies.issue/3` mints an id on join when the payload carries none, which
  is why a checkout and a harness are the same thing. Returns the join reply,
  which carries the minted `working_copy_id`.
  """
  @spec join_working_copy(map(), String.t(), String.t(), keyword()) :: map()
  def join_working_copy(context, root, label, opts \\ []) do
    {reply, _socket} = join_working_copy_socket(context, root, label, opts)
    reply
  end

  @doc """
  The same join, keeping the socket.

  For criteria that go on to send on that channel — reporting an agent's steps,
  say. Joining a second time for the same checkout is refused rather than
  allowed, and correctly so: two harnesses on one copy share a `_build`. So the
  socket has to come back from the join that made the copy, not from a second
  one beside it.
  """
  @spec join_working_copy_socket(map(), String.t(), String.t(), keyword()) ::
          {map(), Phoenix.Socket.t()}
  def join_working_copy_socket(context, root, label, opts \\ []) do
    {:ok, reply, socket} =
      UserSocket
      |> socket("spex-1019-#{label}", %{scope: context.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{context.project.id}",
        join_payload(context, root, label, opts)
      )

    {reply, socket}
  end

  # The device the harness is announcing from.
  #
  # Named explicitly when a criterion is about which machine a checkout is on,
  # and otherwise a fresh one, because a join that names no machine is refused:
  # a checkout is identified by {project, device, root}, and two boxes share a
  # path constantly. This used to omit it, on the reasoning that a payload with
  # no device is what a harness built before devices sends — true then, and that
  # harness can no longer join at all.
  defp join_payload(context, root, label, opts) do
    base = %{"working_copy_id" => opts[:working_copy_id], "root" => root, "label" => label}

    base
    |> put_device(context, Keyword.fetch(opts, :device_id))
    |> put_preview(Keyword.fetch(opts, :preview_url))
  end

  defp put_device(payload, _context, {:ok, device_id}),
    do: Map.put(payload, "device", %{"id" => device_id})

  defp put_device(payload, context, :error),
    do: Map.put(payload, "device", %{"id" => Fixtures.device_fixture(context.scope).id})

  # Where this checkout says its preview answers. Absent unless a criterion is
  # about it, for the same reason the device is: a payload without one is what a
  # checkout that has no preview sends, and that is a real state rather than a
  # thing to be filled in.
  defp put_preview(payload, {:ok, url}), do: Map.put(payload, "preview_url", url)
  defp put_preview(payload, :error), do: payload

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

  @doc """
  Have the lane on a copy say something, the way a Pi lane says it.

  `agent_message` keyed `pi:<root>` is the real up path — a lane pushes it, the
  proxy relays it, and the channel persists it onto that copy's conversation.
  Used to plant a line that identifies *which* conversation a page landed on:
  the transcript itself is the evidence, so a link that opened a different one
  shows up as the line being missing rather than as an id assertion that can
  pass on a truncated render.
  """
  @spec agent_says(map(), String.t(), String.t()) :: :ok
  def agent_says(context, root, text) do
    {:ok, _reply, socket} =
      UserSocket
      |> socket("spex-1019-says", %{scope: context.scope})
      |> subscribe_and_join(
        HarnessChannel,
        "harness:#{context.scope.active_account_id}",
        %{}
      )

    Phoenix.ChannelTest.push(socket, "agent_message", %{
      "external_id" => "pi:#{root}",
      "project_id" => context.project.id,
      "role" => "assistant",
      "kind" => "text",
      "text" => text
    })

    # `agent_message` is answered with `{:noreply, …}`, so there is no ack to
    # wait on. `close/1` blocks until the channel process is down, and a channel
    # handles its mailbox in order — so the push is persisted before this
    # returns. Ordered, not timed.
    #
    # Trapped because `subscribe_and_join` links the channel to the caller, so
    # the close that provides the ordering also takes the test down with it
    # (`** (EXIT from …) shutdown: :closed`). The flag is restored rather than
    # left on: a spex that silently stops dying on linked crashes hides the next
    # failure instead of reporting it.
    trapping = Process.flag(:trap_exit, true)
    Phoenix.ChannelTest.close(socket)
    receive do: ({:EXIT, _pid, _reason} -> :ok), after: (0 -> :ok)
    Process.flag(:trap_exit, trapping)
    :ok
  end

  @doc """
  One Pi agent on a copy, as a harness would report it.

  Takes the harness id because that is what the wire carries: the device reads
  it out of the checkout's own `.cms_harness.json` and the server joins on it.
  A criterion gets one from `join_working_copy/3`'s reply, which is the same
  route a real checkout takes — minted on join, then presented.
  """
  @spec pi_agent(String.t(), String.t()) :: map()
  def pi_agent(working_copy_id, root),
    do: %{
      "harness_id" => working_copy_id,
      "working_copy" => root,
      "provider" => "zai",
      "engine" => "pi"
    }

  @doc "One Claude Code agent on a copy, as a harness would report it."
  @spec claude_agent(String.t(), String.t()) :: map()
  def claude_agent(working_copy_id, root),
    do: %{
      "harness_id" => working_copy_id,
      "working_copy" => root,
      "provider" => "anthropic",
      "engine" => "claude_code"
    }
end
