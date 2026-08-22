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

  They are not indistinguishable any more, though not from inside that function
  — `corroborate_with_disk/2` asks whether the project moved while the task ran,
  which a broken recording cannot hide and a session that edited nothing cannot
  fake. So an empty set demotes, and `76008385` is what the old shape cost: a QA
  agent, which writes no project files by nature, hit it on every stop and had
  no action available that would change the answer.

  The note stays, with the opposite content. Silence would be wrong in the
  other direction: an agent whose findings all became advisory should know why
  they stopped blocking, and that the reason is a claim about this session
  rather than a judgment that the findings do not matter.

  Both notes are pinned on their wording, not just their existence, because
  both have been wrong in the field while reading as authoritative. 339725c7
  announced a blanket demotion in the same paragraph as two exceptions the gate
  no longer makes, directly under 26 findings it was still blocking on; and the
  empty-set note told a QA agent it had "no recorded edits" moments after it
  wrote its brief, because the brief lives somewhere git ignores (a9e9caca).
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

  test "a session that changed no tracked file is told its findings were demoted" do
    text = render(MapSet.new())

    assert text =~ "changed no file this project tracks"
    assert text =~ "demoted to advisory"

    assert text =~ "git log -1 -- <path>",
           "the findings are still someone's — the note stops asking the agent to " <>
             "do the attribution, but still says how to find the owner"

    refute text =~ "nothing was demoted",
           "the old wording told the agent the opposite of what now happens, which " <>
             "is worse than saying nothing at all"
  end

  # 339725c7 read as the gate being broken, and fairly: the same paragraph
  # announced a blanket demotion and named two categories that were still
  # blocking, with 26 of them listed directly above it.
  test "it does not promise exceptions the demotion no longer makes" do
    text = render(MapSet.new())

    refute text =~ "still block",
           "spex and file-less findings are demoted too under story 894's rule. " <>
             "Naming an exception the gate does not make is what made this message " <>
             "contradict the 26 blocking findings printed above it."
  end

  # The QA session this is mostly written for did record edits — to
  # `.code_my_spec/qa/…`, which git ignores and `Files` therefore never rows.
  # Telling it that it has "no recorded edits" reads as the gate being wrong
  # about a file it just wrote.
  test "it claims nothing about what was recorded, only about what changed here" do
    refute render(MapSet.new()) =~ "no recorded edits"
  end

  test "a session whose attribution is unusable is told that too" do
    text = render(nil)

    assert text =~ "names a file the project has a record of"
    assert text =~ "git log -1 -- <path>"
  end

  # `nil` means one specific thing — project files changed and nothing recorded
  # names a file the project knows — and the note is only actionable if it says
  # which.
  test "the unusable note describes the evidence rather than asserting a verdict" do
    text = render(nil)

    assert text =~ "changed while this task ran"

    assert text =~ "create_issue",
           "paths that could never name a file here are a real defect, and the agent " <>
             "is the only party positioned to report one"
  end

  # Two agents filed the same issue in one day (07bcd520, 6c27799f) because the
  # note said their recording was broken. It was not: they had each edited a
  # file created that turn, which the scanner had not reached, so it had no row
  # to match against. Both concluded sub-agent edits go unrecorded — a mechanism
  # that does not exist — and each spent a report on it.
  test "it names the ordinary cause before the defect" do
    text = render(nil)

    assert text =~ "a file created this turn",
           "the common reason to land here is a new file with no record yet, and a " <>
             "note that leads with 'the recording is broken' sends the reader to " <>
             "file an issue instead"

    assert text =~ "clears this by itself",
           "and it resolves on its own once the scan runs, which is the difference " <>
             "between waiting and reporting"
  end

  test "and it no longer calls a good ledger broken" do
    refute render(nil) =~ "the recording itself is wrong",
           "that sentence was true of one cause and read as true of all of them"
  end

  # The note is about the gate having no evidence. With evidence it has already
  # spoken — the finding either carries "(not edited by this session)" or was
  # demoted out of the blocking list entirely — and repeating it would be noise
  # on every ordinary stop.
  test "a session with recorded edits gets no note" do
    text = render(MapSet.new(["lib/code_my_spec/validation.ex"]))

    refute text =~ "changed no file this project tracks"
    refute text =~ "edit ledger"
  end

  # The distinction the whole thing turns on: this one is the session's own
  # work, and telling it to go read git blame would be wrong.
  test "a finding in a file the session did edit is still marked as its own" do
    text = render(MapSet.new(["test/spex/886_preview/criterion_2328_spex.exs"]))

    refute text =~ "not edited by this session"
    refute text =~ "changed no file this project tracks"
  end
end
