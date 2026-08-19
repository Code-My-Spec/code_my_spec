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
  its recorded paths are demoted to advisory. An empty path set used to be
  refused alongside an unusable one, because "the session wrote nothing" and
  "attribution broke" were indistinguishable from there.

  They are not indistinguishable any more — `verify_against_ledger/3` answers
  `nil` for the broken case specifically — so an empty set now demotes, and
  `76008385` is what the old shape cost: a QA agent, which writes no project
  files by nature, hit it on every stop and had no action available that would
  change the answer.

  The note stays, with the opposite content. Silence would be wrong in the
  other direction: an agent whose findings all became advisory should know why
  they stopped blocking, and that the reason is a claim about this session
  rather than a judgment that the findings do not matter.

  The unusable case is unchanged and still blocks everything.
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

  test "a session with no recorded edits is told its findings were demoted" do
    text = render(MapSet.new())

    assert text =~ "no recorded edits"
    assert text =~ "demoted to advisory"

    assert text =~ "git log -1 -- <path>",
           "the findings are still someone's — the note stops asking the agent to " <>
             "do the attribution, but still says how to find the owner"

    refute text =~ "nothing was demoted",
           "the old wording told the agent the opposite of what now happens, which " <>
             "is worse than saying nothing at all"
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
