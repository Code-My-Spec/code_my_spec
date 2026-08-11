defmodule CodeMySpec.Environments.NoAmbientDirectoryTest do
  @moduledoc """
  An environment that does not know its directory must not borrow the caller's.

  `c8264c1f` reported two exunit failures that passed standalone and blamed
  concurrency with the live analyzer. Neither instance survives — one test was
  deleted in 19db8d21 and the other was `cbe216dd`, whose cause was proven and
  fixed in fcbe8556. What did survive is the observation nobody had explained:
  a fixture whose cwd was a temp directory saw 28 problems carrying absolute
  paths *under the worktree*, which a correctly isolated run cannot produce.

  `Local.cmd/4` left `:cd` unset when the environment had no cwd, so the command
  ran wherever the OS process happened to be — the developer's own checkout —
  and its warnings were reconciled into whichever project the scope named. Same
  for `stream_files/3`, which globbed from `File.cwd!()`.

  Measured before changing either: across the whole suite exactly one call
  reaches `cmd/4` without a cwd, and it is `echo` in a test of the recorder;
  `stream_files/3` gets none. Nothing relied on the fallback. It only waited.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @nowhere %Environment{type: :local, cwd: nil}

  test "running a command without a working directory is refused" do
    assert_raise ArgumentError, ~r/no working directory/, fn ->
      Environments.cmd(@nowhere, "mix", ["compile"], [])
    end
  end

  # The message has to say why, because the fix is at the call site that built
  # the environment and not here.
  test "the refusal says what would have gone wrong" do
    error =
      assert_raise ArgumentError, fn ->
        Environments.cmd(@nowhere, "mix", ["compile"], [])
      end

    assert error.message =~ "analyse the wrong project"
    assert error.message =~ "explicit cwd"
  end

  test "scanning for files without a working directory is refused" do
    assert_raise ArgumentError, ~r/no working directory/, fn ->
      Environments.Local.stream_files(@nowhere, ["lib"], [])
    end
  end

  # `Cli` is a second implementation of the same behaviour and carried the same
  # fallback. 9770cea7 fixed `Local` and left this one, which is how a fix goes
  # stale across implementations: the hazard just moves to whichever the next
  # caller picks. Asserted per implementation rather than once, because that is
  # the failure this pins.
  test "the CLI environment refuses it too" do
    assert_raise ArgumentError, ~r/no working directory/, fn ->
      Environments.Cli.stream_files(%Environment{type: :cli, cwd: nil}, ["lib"], [])
    end
  end

  # The point is refusing the *absent* directory, not refusing ambient work: a
  # caller that means "here" says "here" and still gets it.
  test "an explicit directory still runs" do
    env = Environment.new(:local, File.cwd!())

    assert {output, 0} = Environments.cmd(env, "pwd", [], [])
    assert String.trim(output) == File.cwd!()
  end
end
