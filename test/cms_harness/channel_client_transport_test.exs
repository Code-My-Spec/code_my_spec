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

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Project.Transport

  setup do
    Process.put({Transport, :impl}, CmsHarness.Project.Transport.Test)
    Process.put({CmsHarness.Project.Transport.Test, :owner}, self())
    :ok
  end

  test "a recorder selected here does not replace another process's real transport" do
    other = Task.async(fn -> Transport.impl() end)

    assert Task.await(other, :infinity) == CmsHarness.Project.Transport.Slipstream
    assert Transport.impl() == CmsHarness.Project.Transport.Test
  end

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
    payload = %{"run_id" => 42, "source" => "credo", "status" => "ok"}

    assert {:noreply, out} =
             ChannelClient.handle_cast({:analysis_result, payload}, socket(%{analysis_refs: %{}}))

    assert_receive {:transport_push, _, "analysis_result", ^payload, ref}

    assert out.assigns.analysis_refs[ref] == payload

    assert out.assigns.analysis_pending[42] == payload,
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

  test "a graph rebuild defers restoration and retries the handshake" do
    ref = make_ref()
    sock = socket(%{restore_ref: ref, restored: false})

    assert {:ok, waiting} =
             ChannelClient.handle_reply(
               ref,
               {:error, %{"reason" => "graph_rebuilding", "retry_after_ms" => 5_000}},
               sock
             )

    refute waiting.assigns.restored
    assert is_nil(waiting.assigns.restore_ref)
    assert_receive :retry_restore_after_graph, 5_500
    assert {:noreply, retrying} = ChannelClient.handle_info(:retry_restore_after_graph, waiting)
    assert_receive {:transport_push, "harness_project:p1", "agents_to_restore", %{}, retry_ref}
    assert retrying.assigns.restore_ref == retry_ref

    assert {:noreply, _} = ChannelClient.handle_info(:retry_restore_after_graph, retrying)
    refute_received {:transport_push, _, "agents_to_restore", _, _}

    assert {:noreply, _} =
             ChannelClient.handle_info(:retry_restore_after_graph, socket(%{joined: false}))

    refute_received {:transport_push, _, "agents_to_restore", _, _}
  end

  test "join still asks what to restore, immediately" do
    assert {:ok, _out} =
             ChannelClient.handle_join(
               "harness_project:p1",
               %{},
               socket(%{project: %{id: "p1", root: "/tmp/x", working_copy_id: nil}})
             )

    assert_receive {:transport_push, "harness_project:p1", "agents_to_restore", _, _},
                   1_000,
                   "delaying the self-report must not delay the ask — a restore that " <>
                     "waits behind the delayed report would just move the race rather " <>
                     "than close it"
  end

  # `00121aa6`. The server answers `agents_to_restore` by writing a "harness
  # restarted" notice to every agent, so asking on each reconnect told every
  # agent twice or more per restart.
  test "a rejoin after a dropped connection does not ask what to restore again" do
    sock =
      socket(%{
        joined: false,
        attempts: 0,
        pending: %{},
        project: %{id: "p1", root: "/tmp/x", working_copy_id: nil}
      })

    {:ok, joined} = ChannelClient.handle_join("harness_project:p1", %{}, sock)
    assert_receive {:transport_push, "harness_project:p1", "agents_to_restore", _, ref}, 1_000

    {:ok, restored} = ChannelClient.handle_reply(ref, {:ok, %{"agents" => []}}, joined)

    {:ok, dropped} =
      capture_log_result(fn -> ChannelClient.handle_disconnect(:closed_by_remote, restored) end)

    {:ok, _rejoined} = ChannelClient.handle_join("harness_project:p1", %{}, dropped)

    refute_receive {:transport_push, _, "agents_to_restore", _, _},
                   100,
                   "a reconnect lost no agent; asking again writes a second restart notice"
  end

  test "a join whose restore was refused asks again on the next join" do
    sock = socket(%{project: %{id: "p1", root: "/tmp/x", working_copy_id: nil}})

    {:ok, joined} = ChannelClient.handle_join("harness_project:p1", %{}, sock)
    assert_receive {:transport_push, "harness_project:p1", "agents_to_restore", _, ref}, 1_000

    {:ok, refused} =
      capture_log_result(fn ->
        ChannelClient.handle_reply(ref, {:error, %{"reason" => "boom"}}, joined)
      end)

    {:ok, _} = ChannelClient.handle_join("harness_project:p1", %{}, refused)
    assert_receive {:transport_push, "harness_project:p1", "agents_to_restore", _, _}, 1_000
  end

  # Harness session: a harness that starts while :4000 is down fails its first
  # connects; the restore still happens exactly once, on the first join that lands.
  test "a harness that starts while the server is down restores once, on its first join" do
    sock =
      socket(%{
        joined: false,
        attempts: 0,
        pending: %{},
        project: %{id: "p1", root: "/tmp/x", working_copy_id: nil}
      })

    {:ok, refused} =
      capture_log_result(fn -> ChannelClient.handle_disconnect(:econnrefused, sock) end)

    refute_receive {:transport_push, _, "agents_to_restore", _, _}, 100

    {:ok, joined} = ChannelClient.handle_join("harness_project:p1", %{}, refused)
    assert_receive {:transport_push, "harness_project:p1", "agents_to_restore", _, ref}, 1_000

    {:ok, restored} = ChannelClient.handle_reply(ref, {:ok, %{"agents" => []}}, joined)

    {:ok, dropped} =
      capture_log_result(fn -> ChannelClient.handle_disconnect(:closed_by_remote, restored) end)

    {:ok, _} = ChannelClient.handle_join("harness_project:p1", %{}, dropped)

    refute_receive {:transport_push, _, "agents_to_restore", _, _},
                   100,
                   "restored on the first join that landed; a later join must not ask again"
  end

  defp capture_log_result(fun) do
    {result, _log} = with_log(fun)
    result
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
      root = CodeMySpec.TempFile.dir("cms_join_id")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    defp join(root, held, reply) do
      sock = socket(%{project: %{id: "p1", root: root, working_copy_id: held}})
      {:ok, out} = ChannelClient.handle_join("harness_project:p1", reply, sock)
      out
    end

    test "a first join writes down the id it is given", %{root: root} do
      out = join(root, nil, %{"harness_id" => "h_issued"})

      assert {:ok, %{working_copy_id: "h_issued"}} = HarnessConfig.read(root),
             "without this the next restart is issued a second id and orphans this one's rows"

      assert out.assigns.project.working_copy_id == "h_issued"
    end

    test "a server that does not know the field changes nothing", %{root: root} do
      out = join(root, nil, %{})

      assert :none = HarnessConfig.read(root)
      assert out.assigns.project.working_copy_id == nil
      assert out.assigns.joined, "the join still succeeds — this half can land first"
    end

    test "being re-issued the same id is a no-op", %{root: root} do
      :ok = HarnessConfig.write(root, %{working_copy_id: "h_held", project_id: "p1", root: root})
      out = join(root, "h_held", %{"harness_id" => "h_held"})

      assert {:ok, %{working_copy_id: "h_held"}} = HarnessConfig.read(root)
      assert out.assigns.project.working_copy_id == "h_held"
    end

    test "a conflicting id is named, not adopted", %{root: root} do
      :ok = HarnessConfig.write(root, %{working_copy_id: "h_held", project_id: "p1", root: root})

      log =
        capture_log(fn ->
          out = join(root, "h_held", %{"harness_id" => "h_different"})

          assert out.assigns.project.working_copy_id == "h_held",
                 "this copy's rows are filed under h_held; adopting h_different " <>
                   "would orphan them while everything kept looking healthy"
        end)

      assert log =~ "already holds"
      assert {:ok, %{working_copy_id: "h_held"}} = HarnessConfig.read(root)
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

  describe "a working copy someone else is serving" do
    # Two harnesses on one *project* is ordinary now. What is refused is a second
    # harness on the same working copy — they cannot share `_build`, and two
    # `mix test` runs in one build tree corrupt it.
    #
    # That refusal clears the moment the holder exits, so this retries forever at
    # the capped backoff. It used to give up permanently, from when the refusal
    # meant file corruption, and nothing ever cleared the flag — so a harness
    # refused once stayed dead for the life of the process and survived a server
    # restart still reporting the server as the problem.
    defp refuse(socket, reason \\ "working_copy_in_use") do
      ChannelClient.handle_topic_close(
        "harness_project:p1",
        {:failed_to_join,
         %{"reason" => reason, "held_by" => "another harness on this working copy"}},
        socket
      )
    end

    test "the first refusal retries" do
      {:ok, _out} = refuse(socket(%{attempts: 0, refusals: 0}))

      assert_receive :reconnect, 1_500
    end

    test "a refusal that keeps coming back still retries" do
      out =
        Enum.reduce(1..8, socket(%{attempts: 0, refusals: 0}), fn _, acc ->
          {:ok, next} = refuse(acc)
          next
        end)

      assert out.assigns.refusals == 8

      assert_receive :reconnect,
                     1_500,
                     "the holder exits eventually; giving up means a harness that never " <>
                       "notices and reports the server as broken instead"
    end

    test "a server older than the grain change is still understood" do
      {:ok, out} = refuse(socket(%{attempts: 0, refusals: 0}), "project_in_use")

      assert out.assigns.refused == :working_copy_in_use,
             "the reason string changed with the grain; both are accepted so a " <>
               "harness can serve either server"
    end

    test "a refusal does not stop the reconnect on the next disconnect" do
      # `refused` is set directly rather than by driving `refuse/1` eight times.
      # That drove the real path but armed a rejoin timer per refusal, the first
      # at 1000ms, and `receive_all_reconnects/0` drains for 50ms — so those
      # timers were still pending, not drained, and the assertion below was
      # satisfied by a refusal's own timer about a second later. The test passed
      # for two months with the bug present.
      #
      # Nothing here arms a timer but `handle_disconnect/2`, so nothing else can
      # satisfy it.
      refused_socket =
        socket(%{attempts: 0, refusals: 8, pending: %{}, refused: :working_copy_in_use})

      refute_receive :reconnect, 50, "the fixture must arm nothing of its own"

      {:ok, _out} = ChannelClient.handle_disconnect(:closed, refused_socket)

      assert_receive :reconnect,
                     2_000,
                     "this is the bug: `refused` gated the reconnect, so a harness that " <>
                       "had been refused could not come back when the server did — two " <>
                       "subtrees in one harness met the same server restart and only the " <>
                       "one that had never been refused returned"
    end
  end

  # A topic close used to dial a second connection beside the first. The new
  # join evicted the old channel, its death came back as another close, and one
  # harness held 195 sockets with hooks refused every few seconds (2026-10-18).
  describe "a reconnect while a connection is up" do
    test "drops that connection instead of dialing beside it" do
      sock = %{socket(%{joined: false, attempts: 0, pending: %{}}) | channel_pid: self()}

      {:noreply, _out} = ChannelClient.handle_info(:reconnect, sock)

      assert_receive {:transport_disconnect, "harness_project:p1"},
                     1_000,
                     "the drop hands the dial to `handle_disconnect/2`, after the old socket is gone"
    end

    test "a close that lands as a join completes leaves the join alone" do
      sock = %{socket(%{joined: true, attempts: 0, pending: %{}}) | channel_pid: self()}

      assert {:noreply, ^sock} = ChannelClient.handle_info(:reconnect, sock)
      refute_received {:transport_disconnect, _}
    end
  end

  describe "the reconnect backoff survives a join that does not work" do
    # Measured 2026-09-23: four harness instances ran join -> push read_model ->
    # {:error, %{"reason" => "unmatched topic"}} -> disconnect -> backoff(0) =
    # 1000ms -> join, about once a second, indefinitely. One logged 2,777
    # read-model refusals against 1,130 disconnects; together they wrote ~370
    # lines a minute and rotated harness.log's 10MB file every ~35 minutes, so
    # the retained harness history was under two hours old.
    #
    # The backoff table ([1s, 2s, 5s, 10s, 30s]) only ever reached its first
    # entry, because every cycle passed through handle_join/3 and zeroed
    # `attempts`. Joining is not evidence the connection works.
    test "joining does not reset attempts, because a join can be followed by a refusal" do
      root = Path.join(System.tmp_dir!(), "backoff-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      sock =
        socket(%{
          attempts: 3,
          refusals: 2,
          project: %{id: "p1", root: root, working_copy_id: "h1"}
        })

      {:ok, out} = ChannelClient.handle_join("harness_project:p1", %{}, sock)

      assert out.assigns.attempts == 3,
             """
             A join reset the reconnect backoff, so a channel that joins and is
             refused one push later retries at the table's first entry forever.
             """

      assert out.assigns.refusals == 0,
             "refusals are about the server's verdict on this join and do reset"
    end

    test "handing over the read model does reset attempts" do
      ref = make_ref()

      # `:refresh` with an identical model so `maybe_sync/3` stays its hand — the
      # sync path needs a live task registry and is not what this asserts.
      sock =
        socket(%{
          attempts: 4,
          read_model_ref: ref,
          read_model_reason: :refresh,
          read_model: %CodeMySpec.Files.Scanner.ReadModel{}
        })

      {:ok, out} = ChannelClient.handle_reply(ref, {:ok, %{}}, sock)

      assert out.assigns.attempts == 0,
             """
             The read model is what the join exists to obtain — a scan without one
             resolves no owners. A connection that has handed one over has proved
             it works, and that is where the backoff is allowed to forget.
             """
    end

    test "a refused read model leaves attempts alone so the backoff can grow" do
      ref = make_ref()
      sock = socket(%{attempts: 4, read_model_ref: ref, read_model_reason: :join})

      {:ok, out} =
        ChannelClient.handle_reply(ref, {:error, %{"reason" => "unmatched topic"}}, sock)

      assert out.assigns.attempts == 4,
             """
             `unmatched topic` is structural, not transient. Retrying it at the
             first backoff entry is what shredded the log; the count has to carry
             so the next disconnect waits longer.
             """
    end
  end

  # b5f7fdb4: a refused read model was re-asked every refresh tick, each at error.
  describe "an unmatched-topic read model refusal" do
    test "stops the refresh until the next join" do
      ref = make_ref()
      sock = socket(%{read_model_ref: ref, read_model_reason: :refresh})

      {:ok, refused} =
        capture_log_result(fn ->
          ChannelClient.handle_reply(ref, {:error, %{"reason" => "unmatched topic"}}, sock)
        end)

      assert {:noreply, _} = ChannelClient.handle_info(:refresh_read_model, refused)
      refute_receive {:transport_push, _, "read_model", _, _}, 50
    end

    test "a join asks again" do
      root = Path.join(System.tmp_dir!(), "refused-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      sock =
        socket(%{
          read_model_refused: true,
          project: %{id: "p1", root: root, working_copy_id: "h1"}
        })

      {:ok, joined} = ChannelClient.handle_join("harness_project:p1", %{}, sock)
      assert_receive {:transport_push, _, "read_model", _, _}, 1_000

      assert {:noreply, _} = ChannelClient.handle_info(:refresh_read_model, joined)
      assert_receive {:transport_push, _, "read_model", _, _}, 1_000
    end

    test "logs at error once, then below error" do
      ref = make_ref()
      sock = socket(%{read_model_ref: ref, read_model_reason: :join})
      refusal = {:error, %{"reason" => "unmatched topic"}}

      {{:ok, out}, first} = with_log(fn -> ChannelClient.handle_reply(ref, refusal, sock) end)
      assert first =~ "[error]"

      {_, again} = with_log(fn -> ChannelClient.handle_reply(ref, refusal, out) end)
      # with_log sees every process's logs and this file runs async, so check
      # only this refusal's own line, not any [error] another test logged.
      refute again =~ "would not hand over the read model"
    end
  end

  # 57aa576c. Slipstream times neither the upgrade nor the join reply, so a dial
  # the server never answers left the client alive, unjoined and never
  # disconnected — and the backoff only runs from a disconnect.
  describe "a dial that never joins" do
    defp dialing(assigns) do
      socket(Map.merge(%{joined: false, attempts: 0, pending: %{}}, assigns))
    end

    test "an upgraded socket whose join is never answered is dropped" do
      ref = make_ref()
      sock = %{dialing(%{join_attempt: ref}) | channel_pid: self()}

      {{:noreply, _out}, log} =
        with_log(fn -> ChannelClient.handle_info({:join_deadline, ref}, sock) end)

      assert_receive {:transport_disconnect, "harness_project:p1"},
                     1_000,
                     "dropping the socket is what hands the retry to `handle_disconnect/2`"

      assert log =~ "the join was never answered"
    end

    test "an upgrade that never answers is abandoned and dialed again" do
      ref = make_ref()

      {{:noreply, out}, log} =
        with_log(fn ->
          ChannelClient.handle_info({:join_deadline, ref}, dialing(%{join_attempt: ref}))
        end)

      assert_receive {:transport_abandon, "harness_project:p1"}, 1_000

      assert_receive :reconnect,
                     2_000,
                     "no disconnect follows an upgrade that never answered, so nothing " <>
                       "else will ever schedule the next dial"

      assert out.assigns.attempts == 1
      assert log =~ "the websocket upgrade was never answered"
    end

    test "a deadline from an attempt that already ended does nothing" do
      ref = make_ref()
      sock = %{dialing(%{join_attempt: make_ref()}) | channel_pid: self()}

      assert {:noreply, _} = ChannelClient.handle_info({:join_deadline, ref}, sock)
      refute_receive {:transport_disconnect, _}, 100
    end

    test "a deadline after the join landed does nothing" do
      ref = make_ref()
      sock = %{dialing(%{join_attempt: ref, joined: true}) | channel_pid: self()}

      assert {:noreply, _} = ChannelClient.handle_info({:join_deadline, ref}, sock)
      refute_receive {:transport_disconnect, _}, 100
    end

    test "a disconnect retires the attempt's deadline" do
      ref = make_ref()

      {:ok, out} =
        capture_log_result(fn ->
          ChannelClient.handle_disconnect(:closed, dialing(%{join_attempt: ref}))
        end)

      assert {:noreply, _} = ChannelClient.handle_info({:join_deadline, ref}, out)

      refute_receive {:transport_abandon, _},
                     100,
                     "a stale deadline after a disconnect would schedule a second reconnect"
    end
  end

  # 8c04a700. The restore launched inline, ~20s per agent, and every
  # `stop_agent` push queued behind it until the server's stop timed out. It
  # runs in a task now; this process owns the queue and the task asks it for
  # each agent. Here the test process plays this client to the real task.
  describe "a restore in progress" do
    defp restoring(assigns), do: socket(Map.merge(%{joined: true, pending: %{}}, assigns))

    defp agent(id), do: %{"agent_id" => id, "working_copy" => "/nonexistent/#{id}"}

    defp stop(socket, agent_id, ref) do
      {:ok, out} =
        ChannelClient.handle_message(
          "harness_project:p1",
          "stop_agent",
          %{"ref" => ref, "agent_id" => agent_id},
          socket
        )

      out
    end

    defp next_restore(socket) do
      assert_receive {:"$gen_call", from, :next_restore}, 5_000
      {:reply, reply, out} = ChannelClient.handle_call(:next_restore, from, socket)
      {from, reply, out}
    end

    test "a stop for an agent queued behind a slow launch answers at once, and it never starts" do
      {_, log} =
        with_log(fn ->
          {:ok, sock} =
            ChannelClient.handle_reply(
              :restore,
              {:ok, %{"agents" => [agent("a"), agent("b")]}},
              restoring(%{restore_ref: :restore})
            )

          # The task has been handed `a` and is launching it; the reply is held
          # here, so that launch has not returned.
          {from, {:launch, %{"agent_id" => "a"}} = launch, sock} = next_restore(sock)

          sock = stop(sock, "b", "r1")

          assert_receive {:transport_push, _, "agent_stop_result",
                          %{"status" => "ok", "ref" => "r1"}, _},
                         100,
                         "a queued agent's stop waited for the launch ahead of it"

          GenServer.reply(from, launch)
          {from, reply, _sock} = next_restore(sock)
          GenServer.reply(from, reply)

          assert reply == :done, "the stopped agent was still handed to the restore"
        end)

      refute log =~ "agent b", "b was launched after it was stopped"
    end

    test "a stop for the agent being launched waits for the launch, then stops it" do
      sock = restoring(%{restore_queue: [], restoring: "a"})

      sock = stop(sock, "a", "r1")

      refute_receive {:transport_push, _, "agent_stop_result", _, _},
                     100,
                     "stopped before its launch returned, the launch would start it again"

      {:reply, :done, _} = ChannelClient.handle_call(:next_restore, {self(), make_ref()}, sock)

      assert_receive {:transport_push, _, "agent_stop_result", %{"ref" => "r1"}, _}, 1_000
    end
  end

  # Agent presence (`.code_my_spec/plans/agent-liveness-from-presence.md`).
  describe "agent presence" do
    test "join reports the copy's present agents at once" do
      assert {:ok, _out} =
               ChannelClient.handle_join(
                 "harness_project:p1",
                 %{},
                 socket(%{project: %{id: "p1", root: "/tmp/x", working_copy_id: nil}})
               )

      assert_receive {:transport_push, "harness_project:p1", "agents_present",
                      %{"agent_ids" => ids}, _},
                     1_000

      assert is_list(ids)
    end

    test "an agent in this copy coming up is pushed as agent_up" do
      {:noreply, _} =
        ChannelClient.handle_info({:agent_liveness, :up, "a1", "/tmp/x", nil}, socket(%{}))

      assert_receive {:transport_push, "harness_project:p1", "agent_up", %{"agent_id" => "a1"}, _}
    end

    test "its death is pushed as agent_down, with the reason" do
      {:noreply, _} =
        ChannelClient.handle_info({:agent_liveness, :down, "a1", "/tmp/x", :killed}, socket(%{}))

      assert_receive {:transport_push, _, "agent_down",
                      %{"agent_id" => "a1", "reason" => ":killed"}, _}
    end

    test "its harness giving up on it is the final agent_down, marked gave_up" do
      {:noreply, _} =
        ChannelClient.handle_info(
          {:agent_liveness, :gave_up, "a1", "/tmp/x", {:badarg, []}},
          socket(%{})
        )

      assert_receive {:transport_push, _, "agent_down",
                      %{"agent_id" => "a1", "reason" => "gave_up: {:badarg, []}"}, _}
    end

    test "another copy's agent is its own channel's to report" do
      {:noreply, _} =
        ChannelClient.handle_info(
          {:agent_liveness, :up, "a1", "/tmp/elsewhere", nil},
          socket(%{})
        )

      refute_receive {:transport_push, _, "agent_up", _, _}, 100
    end

    test "nothing is pushed while not joined; the next join's set carries it" do
      {:noreply, _} =
        ChannelClient.handle_info(
          {:agent_liveness, :up, "a1", "/tmp/x", nil},
          socket(%{joined: false})
        )

      refute_receive {:transport_push, _, "agent_up", _, _}, 100
    end
  end
end
