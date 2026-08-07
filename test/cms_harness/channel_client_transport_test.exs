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

  import ExUnit.CaptureLog

  alias CmsHarness.HarnessIdentity
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
          %{
            joined: true,
            refused: nil,
            topic: "harness_project:p1",
            project: %{id: "p1", root: "/tmp/x"}
          },
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
    test "an unmatched-topic reply drops the joined flag and drops the connection" do
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

      # The socket, not the topic. This used to schedule a rejoin, and a rejoin
      # is the one thing that cannot work here: Slipstream only joins when its
      # local `join_status` is nil or `:closed`, and the server dropped this
      # channel without sending a close, so it still reads `:joined`. The join
      # was a silent no-op and the harness sat dead for three minutes.
      assert_receive {:transport_disconnect, "harness_project:p1"},
                     1_000,
                     "a stale join has to heal itself; nobody restarts a harness that reports healthy"

      refute_receive :reconnect,
                     200,
                     "the reconnect is `handle_disconnect/2`'s job now — arming a timer here " <>
                       "too would race it and open a second connection"
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

  describe "the identity the server issues" do
    setup do
      root = Path.join(System.tmp_dir!(), "cms_join_id_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    defp join(root, held, reply) do
      sock = socket(%{project: %{id: "p1", root: root, harness_id: held}})
      {:ok, out} = ChannelClient.handle_join("harness_project:p1", reply, sock)
      out
    end

    test "a first join writes down the id it is given", %{root: root} do
      out = join(root, nil, %{"harness_id" => "h_issued"})

      assert {:ok, "h_issued"} = HarnessIdentity.read(root),
             "without this the next restart is issued a second id and orphans this one's rows"

      assert out.assigns.project.harness_id == "h_issued"
    end

    test "a server that does not know the field changes nothing", %{root: root} do
      out = join(root, nil, %{})

      assert :none = HarnessIdentity.read(root)
      assert out.assigns.project.harness_id == nil
      assert out.assigns.joined, "the join still succeeds — this half can land first"
    end

    test "being re-issued the same id is a no-op", %{root: root} do
      :ok = HarnessIdentity.write(root, "h_held")
      out = join(root, "h_held", %{"harness_id" => "h_held"})

      assert {:ok, "h_held"} = HarnessIdentity.read(root)
      assert out.assigns.project.harness_id == "h_held"
    end

    test "a conflicting id is named, not adopted", %{root: root} do
      :ok = HarnessIdentity.write(root, "h_held")

      log =
        capture_log(fn ->
          out = join(root, "h_held", %{"harness_id" => "h_different"})

          assert out.assigns.project.harness_id == "h_held",
                 "this copy's rows are filed under h_held; adopting h_different " <>
                   "would orphan them while everything kept looking healthy"
        end)

      assert log =~ "already holds"
      assert {:ok, "h_held"} = HarnessIdentity.read(root)
    end
  end

  describe "a channel that answers nothing" do
    # The silence twin of the unmatched-topic case above, and the one that cost
    # six minutes on 2026-08-07: four manifests pushed with no reply and roughly
    # fifteen hooks refused `:no_reply`, while a second harness on the same
    # working copy was served normally by the same live server. Nothing said the
    # channel was dead because nothing was said at all — no close, no error
    # reply — so `joined` stayed true and the timeout handler failed each caller
    # and drew no conclusion.
    defp time_out(socket, ref) do
      timer = Process.send_after(self(), :unused, 60_000)
      socket = put_in(socket.assigns.pending, %{ref => {{self(), ref}, timer}})
      ChannelClient.handle_info({:reply_timeout, ref}, socket)
    end

    defp answer(socket, ref) do
      timer = Process.send_after(self(), :unused, 60_000)
      socket = put_in(socket.assigns.pending, %{ref => {{self(), ref}, timer}})
      {:ok, out} = ChannelClient.handle_reply(ref, {:ok, %{}}, socket)
      out
    end

    test "one unanswered decision fails its caller and leaves the join alone" do
      ref = make_ref()

      {:noreply, out} =
        time_out(socket(%{pending: %{}, analysis_refs: %{}, silences: 0, attempts: 0}), ref)

      assert_receive {^ref, {:error, :no_reply}},
                     1_000,
                     "the caller still has to be told; it is the hook's answer"

      assert out.assigns.joined, "one slow answer is not a dead channel"
      assert out.assigns.silences == 1

      refute_receive {:transport_disconnect, _},
                     200,
                     "dropping on the first timeout would reconnect every time the server is busy"
    end

    test "two in a row drop the socket so the reconnect path can run" do
      base = socket(%{pending: %{}, analysis_refs: %{}, silences: 0, attempts: 0})

      {:noreply, once} = time_out(base, make_ref())
      {:noreply, twice} = time_out(once, make_ref())

      refute twice.assigns.joined,
             "believing a join that carries no traffic is what made every later " <>
               "hook refuse with the wrong explanation"

      assert_receive {:transport_disconnect, "harness_project:p1"},
                     1_000,
                     "the socket, not the topic — Slipstream.join/3 is a silent no-op while " <>
                       "join_status still reads joined"

      assert twice.assigns.silences == 0,
             "reset before dropping, or the reconnected channel starts one timeout from death"
    end

    test "a decision that gets answered resets the count" do
      base = socket(%{pending: %{}, analysis_refs: %{}, silences: 0, attempts: 0})

      {:noreply, once} = time_out(base, make_ref())
      recovered = answer(once, make_ref())

      assert recovered.assigns.silences == 0,
             "an answered decision is the only proof the channel carries traffic"

      {:noreply, after_recovery} = time_out(recovered, make_ref())

      assert after_recovery.assigns.joined,
             "two timeouts either side of a healthy answer are not a dead channel"

      refute_receive {:transport_disconnect, _}, 200
    end
  end

  describe "a project someone else holds" do
    # The lease is a Postgres advisory lock on the *server's* connection, so the
    # holder during a server restart is the outgoing node, and it lets go within
    # seconds. Treating the first refusal as final meant a routine restart left
    # the harness permanently not-serving while `cms harness` still looked alive
    # — which is exactly how tonight's outage happened.
    defp refuse(socket) do
      ChannelClient.handle_topic_close(
        "harness_project:p1",
        {:failed_to_join, %{"reason" => "project_in_use", "held_by" => "other@host"}},
        socket
      )
    end

    test "the first refusal retries rather than giving up" do
      {:ok, out} = refuse(socket(%{attempts: 0, refusals: 0}))

      refute out.assigns.refused,
             "a refusal seconds into a server handover is not a second harness"

      assert_receive :reconnect, 1_500
    end

    test "a refusal that keeps coming back is eventually final" do
      out =
        Enum.reduce(1..5, socket(%{attempts: 0, refusals: 0}), fn _, acc ->
          {:ok, next} = refuse(acc)
          next
        end)

      assert out.assigns.refused == :project_in_use,
             "two harnesses on one project corrupt the graph; retrying forever " <>
               "would trade one failure mode for a worse one"

      assert out.assigns.refusals == 5, "the retries are bounded, not endless"
    end
  end
end
