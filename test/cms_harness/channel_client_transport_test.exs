defmodule CmsHarness.ChannelClientTransportTest do
  @moduledoc """
  `ChannelClient` driven with no socket, no server, and no network.

  This module is the most delicate part of the harness — reconnects, reply
  correlation, join refusal, the read-model refresh — and until the transport
  seam existed none of it could be exercised without a live Slipstream
  connection to a running server. So it was tested by running sprite drills,
  which is a forty-minute way to discover that a timer was armed at the wrong
  level or that a reply nobody correlated was being dropped.

  Inbound needed nothing: every `handle_*` is an ordinary function a test can
  call with a socket it built. Only outbound needed a seam, and it is three
  operations wide.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Project.ChannelClient

  setup do
    previous = Application.get_env(:code_my_spec, :harness_transport)
    Application.put_env(:code_my_spec, :harness_transport, CmsHarness.Project.Transport.Test)
    Application.put_env(:code_my_spec, :harness_transport_owner, self())

    on_exit(fn ->
      restore_transport(previous)
      Application.delete_env(:code_my_spec, :harness_transport_owner)
    end)

    :ok
  end

  # Multi-clause rather than an `if`: nothing was configured before this suite
  # and something was are two cases, not a condition.
  defp restore_transport(nil), do: Application.delete_env(:code_my_spec, :harness_transport)

  defp restore_transport(module),
    do: Application.put_env(:code_my_spec, :harness_transport, module)

  defp socket(assigns) do
    %Slipstream.Socket{
      assigns:
        Map.merge(
          %{joined: true, topic: "harness_project:p1", project: %{id: "p1", root: "/tmp/x"}},
          assigns
        )
    }
  end

  test "observations go out as a whole manifest and the reply ref is kept" do
    # The real observation shape — serialize_observation/1 reads every field,
    # so a partial fixture proves the seam and nothing about the payload.
    obs = [
      %{
        path: "lib/a.ex",
        role: :implementation,
        mtime: ~U[2026-08-01 10:00:00.000000Z],
        size: 42,
        fingerprint: "f",
        valid: true,
        validation_errors: %{},
        component_id: nil,
        story_id: nil
      }
    ]

    assert {:noreply, out} = ChannelClient.handle_cast({:observations, obs}, socket(%{}))

    assert_receive {:transport_push, "harness_project:p1", "observations", payload, ref}
    assert length(payload["observations"]) == 1

    assert out.assigns.observations_ref == ref,
           "the ref is what lets the server's answer be read; without it a " <>
             "rejected manifest is indistinguishable from an accepted one"
  end

  test "nothing is sent before the topic is joined" do
    assert {:noreply, _} =
             ChannelClient.handle_cast({:observations, []}, socket(%{joined: false}))

    refute_receive {:transport_push, _, "observations", _, _},
                   100,
                   "pushing before a join loses the manifest silently"
  end

  test "an analysis result is tagged with its source so the reply can be matched" do
    payload = %{"source" => "credo", "status" => "ok"}

    assert {:noreply, out} =
             ChannelClient.handle_cast({:analysis_result, payload}, socket(%{analysis_refs: %{}}))

    assert_receive {:transport_push, _, "analysis_result", ^payload, ref}

    assert out.assigns.analysis_refs[ref] == "credo",
           "a result whose reply cannot be matched back to its source is a run " <>
             "the server may never close"
  end

  test "the read model is re-requested on the refresh tick" do
    assert {:noreply, _} = ChannelClient.handle_info(:refresh_read_model, socket(%{}))

    assert_receive {:transport_push, "harness_project:p1", "read_model", _, _},
                   1_000,
                   "the cache is fetched once on join; without this tick a sprite " <>
                     "holds an empty domain for the whole session"
  end

  describe "a topic the server does not have" do
    # Cost an hour of dogfooding. The server-side channel was gone, no
    # `handle_topic_close/3` ever arrived, and the harness went on believing it
    # was joined: `/health` said `degraded: false`, and every hook refused with
    # a message about timeouts. Nothing self-corrected because the correction
    # was supposed to come from a notification that never came.
    test "an unmatched-topic reply drops the joined flag and rejoins" do
      caller = self()
      ref = make_ref()
      timer = Process.send_after(self(), :unused, 60_000)
      pending = %{ref => {{caller, ref}, timer}}

      {:ok, out} =
        ChannelClient.handle_reply(
          ref,
          {:error, %{"reason" => "unmatched topic"}},
          socket(%{pending: pending, analysis_refs: %{}, attempts: 0})
        )

      refute out.assigns.joined,
             "believing a join the server does not have is what made every " <>
               "later hook fail with the wrong explanation"

      # 1.5s covers the first backoff step (1s) — the rejoin is deliberately not
      # immediate, so a server that is refusing everything is not hammered.
      assert_receive :reconnect,
                     1_500,
                     "a stale join has to heal itself; nobody restarts a harness that reports healthy"
    end

    test "an ordinary error reply leaves the join alone" do
      ref = make_ref()
      timer = Process.send_after(self(), :unused, 60_000)
      pending = %{ref => {{self(), ref}, timer}}

      {:ok, out} =
        ChannelClient.handle_reply(
          ref,
          {:error, %{"reason" => "something_else"}},
          socket(%{pending: pending, analysis_refs: %{}, attempts: 0})
        )

      assert out.assigns.joined, "one bad answer is not a dead channel"
      refute_receive :reconnect, 100
    end
  end
end
