defmodule CodeMySpec.Hooks.ConfigEditNoticeTest do
  @moduledoc """
  A session that edits config is told what it just did to every dev server.

  `5fb011f4`. Phoenix cannot hot-reload `config/*.exs`, by design, so a commit
  that touches one leaves running dev servers answering

      ** (RuntimeError) could not compile application: code_my_spec.
      You must restart your server after changing configuration files

  to every request. The failure is detached from the act in both time and
  space: the edit happens in one worktree, the breakage appears in another
  checkout, minutes later, to whoever touches it next, and nothing in the error
  names the commit. Two dev servers went down at once from two unrelated
  sessions, neither of which did anything wrong.

  Nothing warned at the moment it was still cheap to know. That is the gap this
  closes — not the wedge itself, which is Phoenix behaving as designed.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, UsersFixtures}

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Hooks.Stop

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp}

    # Nothing here is about compiler/credo/exunit/spex content — only
    # whether a config-file edit gets noticed. Without this, every source
    # has never run for this scope, so `decide/2` shells out a real (and
    # here, doomed — `tmp` has no mix.exs) subprocess for each one on
    # every test.
    fresh_analysis_runs_fixture(scope)

    %{scope: scope, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp decide(ctx), do: Stop.decide(ctx.scope, %{"session_id" => ctx.session})

  # An allow with nothing to say carries no `systemMessage` at all, so the
  # absence cases must not assume a string is there to match against.
  defp message(ctx), do: decide(ctx)["systemMessage"] || ""

  test "editing config/dev.exs says so, and says what it costs", ctx do
    :ok = FileEdits.track_edit(ctx.session, "config/dev.exs")

    message = decide(ctx)["systemMessage"]

    assert message =~ "config/dev.exs"
    assert message =~ "cannot hot-reload"
    assert message =~ "restarted"
  end

  # The recovery, because a plain restart does not always clear it — the stale
  # compile.lock survives one. Recorded from the incident rather than guessed.
  test "it gives the recovery that actually works", ctx do
    :ok = FileEdits.track_edit(ctx.session, "config/dev.exs")

    assert decide(ctx)["systemMessage"] =~ "compile.lock"
  end

  test "an absolute path is recognised too", ctx do
    :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.scope.cwd, "config/runtime.exs"))

    assert decide(ctx)["systemMessage"] =~ "config/runtime.exs"
  end

  # Every stop would otherwise carry it, and a footer that is always there is
  # one nobody reads by the third time.
  test "a session that edited no config gets no notice", ctx do
    :ok = FileEdits.track_edit(ctx.session, "lib/code_my_spec/validation.ex")

    refute message(ctx) =~ "hot-reload"
  end

  # `.exs` under a directory called config, not any `.exs` anywhere — test files
  # and spex are `.exs` and vastly outnumber config.
  test "a test file is not mistaken for config", ctx do
    :ok = FileEdits.track_edit(ctx.session, "test/code_my_spec/validation_test.exs")

    refute message(ctx) =~ "hot-reload"
  end

  # A dependency's own config is not this project's to restart for, and `deps/`
  # is full of them.
  test "a dependency's config is not this project's problem", ctx do
    :ok = FileEdits.track_edit(ctx.session, "deps/phoenix/config/config.exs")

    refute message(ctx) =~ "hot-reload"
  end
end
