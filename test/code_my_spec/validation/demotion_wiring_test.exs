defmodule CodeMySpec.Validation.DemotionWiringTest do
  @moduledoc """
  The demotion works through `validate_stop/3`, not just as a pure split.

  `split_unattributed/2` is unit-tested and the renderer is unit-tested, and
  neither touches the part that can actually be wrong: `session_paths/2` reads
  what PostToolUse recorded, relativizes it against `scope.cwd`, and compares
  it to `Problem.file_path`. Three representations have to line up, and the
  ways they fail to are all silent.

  Both recorded shapes are exercised here because both occur. Measured on the
  live database: this session recorded 368 paths, 259 project-relative and 109
  absolute — the harness normalizes repo paths before forwarding, and anything
  outside the working copy (a scratchpad) stays absolute. A guard that only
  handled one shape would look correct against half the traffic.

  What makes this worth an end-to-end test rather than more unit tests: a
  mismatch does not raise. It produces an empty attribution set, which
  `verify_against_ledger/3` reads as "unusable" and answers `nil` to — so the
  gate silently reverts to blocking on everything, which is the old behaviour
  and looks like nothing is wrong.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Validation

  @mine "lib/my_app/mine.ex"
  @theirs "lib/my_app/theirs.ex"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    Configurations.get_or_create(scope)
    {:ok, _} = Configurations.update(scope, %{credo: :block_all})

    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, @mine), "defmodule MyApp.Mine do\nend\n")
    File.write!(Path.join(tmp, @theirs), "defmodule MyApp.Theirs do\nend\n")
    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    %{scope: scope, tmp: tmp, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp stop(scope, session), do: Validation.validate_stop(scope, nil, session_id: session)

  describe "with the session's edits recorded project-relative" do
    setup ctx do
      :ok = FileEdits.track_edit(ctx.session, @mine)
      ctx
    end

    test "a finding in a file it never edited does not block", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:ok, _} = stop(ctx.scope, ctx.session),
             "block_all would block on this; the session did not write it"
    end

    test "a finding in a file it did edit still blocks", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "with both, it blocks and the reason names only its own", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session)
      assert reason =~ @mine
      refute reason =~ "#{@theirs}:", "the other file's finding is advisory, not blocking"
    end
  end

  describe "with the session's edits recorded absolute" do
    test "the path still resolves, so its own finding blocks", ctx do
      # The shape that needs `relativize/2` to do something. If it were a no-op
      # here the set would match nothing, `verify_against_ledger/3` would answer
      # nil, and the gate would block on everything — passing the test above for
      # the wrong reason while demoting nothing.
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, @mine))

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "and a file it never edited is still demoted", ctx do
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, @mine))

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:ok, _} = stop(ctx.scope, ctx.session)
    end
  end

  describe "when attribution names nothing in this project" do
    test "the gate blocks on everything rather than demoting", ctx do
      # The guard from 5d361fb7. A recorded path that corresponds to no file
      # here means the comparison is not usable — and demoting on it would
      # switch the gate off while looking like it worked.
      :ok = FileEdits.track_edit(ctx.session, "/somewhere/else/entirely.ex")

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session),
             "unusable attribution must fail closed, not demote everything"
    end
  end
end
