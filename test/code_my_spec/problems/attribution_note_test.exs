defmodule CodeMySpec.Problems.AttributionNoteTest do
  @moduledoc """
  When the gate cannot tell whose finding this is, it has to say so.

  `7a0fadeb`: an agent's stop blocked on

      test/spex/886_…/criterion_2328_….exs
      module attribute @endpoint was set but never used

  from another agent's in-flight branch, which arrived on a rebase. The obvious
  repair — delete the unused attribute — is actively wrong there: the file
  overrides `@endpoint` to a different endpoint on purpose, and deleting the
  override falls back silently to the one `use CodeMySpecSpex.Case` sets, which
  `~p` and the ConnTest helpers bind at compile time. So the spex would quietly
  talk to the wrong server. Nothing in the response suggested the finding was
  not theirs.

  `5dd2fc02` fixed that for a session that edited *something*: findings outside
  its recorded paths are demoted to advisory. Two states still produce no
  demotion, deliberately — an empty path set and an unusable one — because "the
  session wrote nothing" and "attribution broke" are indistinguishable from
  there, and a gate that quietly stops blocking is invisible where one that
  blocks too much is not.

  The refusal stays. What changes is that it stops being silent: those are
  exactly the stops where every finding may be someone else's, and the agent
  had no marker (`unedited_marker/2` has nothing to compare against) and no
  reason to suspect it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  defp problem do
    %Problem{
      source: "compiler",
      severity: :error,
      file_path: "test/spex/886_preview/criterion_2328_spex.exs",
      line: 1,
      message: "module attribute @endpoint was set but never used"
    }
  end

  defp render(session_paths) do
    ProblemRenderer.render_stop_response([problem()], [], session_paths: session_paths)
  end

  test "a session with no recorded edits is told nothing could be attributed" do
    text = render(MapSet.new())

    assert text =~ "no recorded edits"
    assert text =~ "arrived with a rebase"
    assert text =~ "git log -1 -- <path>"
  end

  test "a session whose attribution is unusable is told that too" do
    text = render(nil)

    assert text =~ "Attribution is unavailable"
    assert text =~ "git log -1 -- <path>"
  end

  # The note is about the gate having no evidence. With evidence it has already
  # spoken — the finding either carries "(not edited by this session)" or was
  # demoted out of the blocking list entirely — and repeating it would be noise
  # on every ordinary stop.
  test "a session with recorded edits gets no note" do
    text = render(MapSet.new(["lib/code_my_spec/validation.ex"]))

    refute text =~ "no recorded edits"
    refute text =~ "Attribution is unavailable"
  end

  # The distinction the whole thing turns on: this one is the session's own
  # work, and telling it to go read git blame would be wrong.
  test "a finding in a file the session did edit is still marked as its own" do
    text = render(MapSet.new(["test/spex/886_preview/criterion_2328_spex.exs"]))

    refute text =~ "not edited by this session"
    refute text =~ "no recorded edits"
  end
end
