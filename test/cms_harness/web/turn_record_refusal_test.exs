defmodule CmsHarness.Web.TurnRecordRefusalTest do
  @moduledoc """
  When a turn cannot be recorded, the harness says which of the two reasons it was.

  `from_id/1` already draws the distinction and its comment says why: "saying
  which is the difference between 'the server is down' and 'this harness is
  misconfigured'". It then answered `nil` to both, so `record/3` could not tell
  a request that named an unresolvable working copy from one that named none —
  and said, in as many words, that the request named none.

  Both lines for one request, one millisecond apart, 2026-08-21:

      turn not recorded: could not resolve b23243bb-… ({:ok, %Req.Response{status: 500 …
      turn not recorded: this request did not name a working copy and this harness
        serves 2 of them … Point ANTHROPIC_BASE_URL at /api/harnesses/<working_copy_id>

  The second is false and its remedy is wrong. The request named a working copy;
  the server was answering 500 because it was mid-recompile. An operator reading
  it re-runs onboarding, which rewrites a correct config and changes nothing.

  The turn itself is unaffected either way — it already reached the agent. What
  is lost is the record of it, and these pin that the log says which loss it was.
  """

  use CmsHarnessTest.ConnCase, async: false

  import ExUnit.CaptureLog
  import CmsHarnessTest.Projects, only: [project_dir: 0, serve: 1, stop_project: 1]

  alias CmsHarnessTest.FakeUpstream

  @unnamed "did not name a working copy"

  setup do
    # The Anthropic side answers 200, because `record/3` only runs on a 200 —
    # this is a test about what happens *after* a successful turn.
    port = FakeUpstream.start!()
    FakeUpstream.respond_with(status: 200, body: ~s({"id":"msg_1","content":[]}))

    previous_upstream = Application.get_env(:code_my_spec, :anthropic_upstream_url)
    Application.put_env(:code_my_spec, :anthropic_upstream_url, "http://127.0.0.1:#{port}")

    # And the server side is unreachable. A closed loopback port rather than a
    # second fake: one `FakeUpstream` answers every path from one
    # `:persistent_term`, so it cannot 200 for Anthropic and fail for the
    # harness lookup at the same time.
    previous_server = Application.get_env(:code_my_spec, :harness_server_url)
    Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:1")

    on_exit(fn ->
      restore_app(:anthropic_upstream_url, previous_upstream)
      Application.put_env(:code_my_spec, :harness_server_url, previous_server)
    end)

    :ok
  end

  defp restore_app(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore_app(key, value), do: Application.put_env(:code_my_spec, key, value)

  defp post_turn(conn, headers) do
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/messages", %{"model" => "claude-opus-5", "messages" => []})
  end

  test "a named working copy that cannot be resolved is not reported as unnamed", %{conn: conn} do
    log =
      capture_log(fn ->
        post_turn(conn, [{"x-harness-id", "b23243bb-e43d-414d-b7e0-7f68db9196d4"}])
      end)

    assert log =~ "could not resolve",
           "the reason the record was lost is the useful half and must still be said"

    refute log =~ @unnamed,
           "the request named a working copy. Saying it did not contradicts the line " <>
             "above it and sends the reader to re-run onboarding on a correct config."
  end

  test "a request that truly names nothing still says so", %{conn: conn} do
    # `working_copy/1`'s fallback for "nothing named" is `served_root/0`: nil
    # unless this harness happens to be serving exactly one project, in which
    # case it silently attributes the turn to it instead. `CmsHarness.Registry`
    # is one registry for the whole node, and other suites register and
    # deregister projects in it while this one runs — so whether the ambient
    # count was exactly one at this millisecond used to decide whether this
    # test passed. Two of our own, left served for the test's duration, push
    # the count to at least two regardless of what else is running, which is
    # the one value `served_root/0` never treats as "exactly one."
    for _ <- 1..2 do
      root = project_dir().root
      serve(root)
      on_exit(fn -> stop_project(root) end)
    end

    log = capture_log(fn -> post_turn(conn, []) end)

    assert log =~ @unnamed,
           "this is the case the message was written for, and suppressing it would " <>
             "trade one wrong answer for no answer"
  end
end
