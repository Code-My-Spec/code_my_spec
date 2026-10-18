defmodule CodeMySpec.Validation.AttributionWithoutCwdTest do
  @moduledoc """
  A scope with no `cwd` still attributes.

  `session_paths/2` was guarded `when is_binary(cwd)`, so a scope without one
  fell to the catch-all and answered `nil` — which disables demotion and blocks
  on every finding, under the message "Attribution is unavailable for this
  session".

  A scope without a `cwd` is the *normal* shape on the light harness: the server
  holds no working copy. So on the deployment the harness exists for, the gate
  reported that it could not check anything against the session's work, while
  the session's work sat in the ledger.

  Measured on the session that found this: 595 recorded edits, 363 already
  project-relative, 269 of them joining File rows for that harness. All
  discarded. Every finding blocked, including ones from other agents' rebases —
  which is exactly the loop 9a623a13 describes, with no exit for a session that
  has correctly determined a finding is not its own.

  The `cwd` was only ever needed to relativize *absolute* paths, and
  `relativize/2` already returns the path unchanged when there is nothing to
  relativize against. The check that actually protects the demotion is
  downstream and unchanged: `verify_against_ledger/3` requires the recorded
  paths to join real File rows and answers `nil` on zero, so a meaningless set
  still demotes nothing.
  """

  # Sandbox.mode(Repo, {:shared, self()}) below is global to the Repo -- a
  # concurrently-running async test can steal connection ownership mid-test.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @session "attribution-no-cwd-session"

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()

    # The shape the harness produces: project-relative paths, no cwd anywhere.
    {2, _rows} =
      Files.upsert_files(scope, [
        %{path: "lib/mine.ex", role: :implementation, fingerprint: "a", valid: true},
        %{path: "lib/theirs.ex", role: :implementation, fingerprint: "b", valid: true}
      ])

    %{scope: %{scope | cwd: nil}}
  end

  # Through the real recorder, not `insert_all`. PostToolUse calls this, so a
  # test that wrote rows directly could pass against a schema the writer no
  # longer produces.
  defp record_edit(path), do: :ok = FileEdits.track_edit(@session, path)

  describe "a scope with no cwd" do
    test "still knows which files the session touched", ctx do
      record_edit("lib/mine.ex")

      paths = Validation.session_paths_for_test(ctx.scope, session_id: @session)

      refute is_nil(paths),
             "nil here is the bug: it reads as 'attribution unavailable' and blocks everything"

      assert MapSet.member?(paths, "lib/mine.ex")
    end

    test "does not claim a file the session never touched", ctx do
      record_edit("lib/mine.ex")

      paths = Validation.session_paths_for_test(ctx.scope, session_id: @session)

      refute MapSet.member?(paths, "lib/theirs.ex"),
             "demotion turns on this set; a false member would block on someone else's file"
    end
  end

  describe "the downstream guard still holds" do
    # The reason dropping the cwd guard is safe. A set that joins no File rows
    # was evidence of nothing here — "a broken recording looks identical to a
    # session that touched none of the project" — so it answered nil and
    # demoted nothing.
    #
    # The two are only identical from inside that function. Disk tells them
    # apart: a mangled recording is mangled *about files that changed*, so they
    # are in this task's changed set. The guard is unchanged in the case it was
    # written for, and no longer catches the QA session in it (a9e9caca).
    test "paths that match no File row block when project files did change", ctx do
      record_edit("/Users/someone/code_my_spec/lib/mine.ex")

      assert is_nil(Validation.session_paths_for_test(ctx.scope, [session_id: @session], true)),
             "the recording names nothing joinable while the project demonstrably " <>
               "changed — attribution is broken and must not demote"
    end

    test "paths that match no File row demote when no project file changed", ctx do
      record_edit(".code_my_spec/qa/884/brief.md")

      paths = Validation.session_paths_for_test(ctx.scope, session_id: @session)

      assert paths == MapSet.new(),
             "a QA session's artifacts are gitignored, so Files never rows them. It " <>
               "did real work and owns no project file; blocking it on the project's " <>
               "red is the loop a9e9caca reported, with no action that would end it."
    end

    test "no session id still answers nil", ctx do
      assert is_nil(Validation.session_paths_for_test(ctx.scope, []))
    end
  end

  describe "splitting on that set" do
    # The split survives as a function with its old shape so the call site and
    # this property stay readable, and it no longer decides anything:
    # `split_unattributed/2` returns every problem as blocking and an empty
    # second list, whatever the touched set says (John, 2026-10-04; 48f4eada —
    # task evaluation judges the whole copy, like promotion).
    #
    # These cases are kept rather than deleted because they are the exact
    # assertion that had to stop being true, and a future change that quietly
    # reintroduces a non-empty second list should fail here first.
    test "a finding on an untouched file is not separated from one on a touched file" do
      touched = MapSet.new(["lib/mine.ex"])

      blocking = [
        %Problems.Problem{file_path: "lib/mine.ex", source: "credo"},
        %Problems.Problem{file_path: "lib/theirs.ex", source: "credo"}
      ]

      {mine, demoted} = Validation.split_unattributed(blocking, touched)

      assert Enum.map(mine, & &1.file_path) == ["lib/mine.ex", "lib/theirs.ex"],
             "a finding in a file this session never opened was demoted. The file a " <>
               "finding is in is not what decides whether it blocks — the mode is."

      assert demoted == []
    end

    test "an empty set demotes nothing either" do
      # Inverted from what this asserted before 8ccd19097. A session that
      # recorded no edits used to own none of the red, which cost a QA agent
      # every stop it made since QA writes no project files at all (76008385).
      # Under the whole-copy rule that is no longer a distinction: the same
      # one-element list comes back, and nothing is excused.
      blocking = [%Problems.Problem{file_path: "lib/theirs.ex", source: "credo"}]

      assert {^blocking, []} = Validation.split_unattributed(blocking, MapSet.new())
    end
  end
end
