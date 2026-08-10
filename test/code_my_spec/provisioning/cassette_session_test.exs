defmodule CodeMySpec.Provisioning.CassetteSessionTest do
  @moduledoc """
  Which cassette session a block is given.

  Sequential cassette state is per-process, and provisioning steps run in
  supervised tasks — so without a shared session each step starts at the top of
  the cassette and replays the earliest matching interaction. `shared: true`
  fixes that by putting the cursor in an Agent, but it starts and stops that
  Agent around *each* block, and a step that outlives its block then reaches a
  dead one:

      ReqCassette shared session Agent is not alive

  That took out four mail spex that had nothing to do with the change. The
  session belongs to the test, so a block is handed the test's — unless there
  isn't one, or it has already died with the process that owned it.
  """
  use ExUnit.Case, async: false

  alias CodeMySpecSpex.Case, as: SpexCase

  setup do
    on_exit(fn -> Process.delete(:cms_cassette_session) end)
    Process.delete(:cms_cassette_session)
    :ok
  end

  test "a block is given the test's session, so it outlives the block" do
    SpexCase.start_cassette_session()
    session = Process.get(:cms_cassette_session)

    opts = SpexCase.cassette_session([])

    assert Keyword.get(opts, :session) == session
    refute Keyword.has_key?(opts, :shared),
           "a per-block session was requested as well, which is what dies early"
  end

  # The session is an `Agent.start_link`, so it dies with the process that
  # started it. A block entered after that — a teardown in `on_exit`, or
  # anything after a crashed test — must get its own rather than a dead pid.
  test "a dead session is not handed on" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    Process.put(:cms_cassette_session, dead)

    opts = SpexCase.cassette_session([])

    refute Keyword.has_key?(opts, :session), "handed on a session that is not alive"
    assert Keyword.get(opts, :shared) == true
  end

  # A spex that never started one still shares across processes within its
  # block, which is what the whole change was for.
  test "with no session at all, the block shares within itself" do
    opts = SpexCase.cassette_session([])

    assert Keyword.get(opts, :shared) == true
    refute Keyword.has_key?(opts, :session)
  end

  # Whatever the caller already decided wins — these are `put_new`.
  test "an explicit session is left alone" do
    SpexCase.start_cassette_session()

    opts = SpexCase.cassette_session(session: :caller_chose)

    assert Keyword.get(opts, :session) == :caller_chose
  end
end
