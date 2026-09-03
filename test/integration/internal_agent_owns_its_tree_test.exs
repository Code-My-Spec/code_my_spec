defmodule CodeMySpec.Integration.InternalAgentOwnsItsTreeTest do
  @moduledoc """
  Regression test: `block_changed` must not demote a finding for an agent
  running under Alloy.

  `block_changed` narrows a source to files the stopping session wrote, and it
  learns that from PostToolUse. An agent inside our own BEAM fires no hooks, so
  nothing is ever attributed to it — and by the time a turn-end decision runs,
  the harness's watcher has already synced the very edit that ought to block.
  The changed set is therefore always empty on that path, which made every
  `block_changed` source permanently advisory.

  QA of story 988 watched it happen: a real Alloy agent created a module with
  no `@moduledoc`, credo recorded the finding and reported `fresh, 2
  problem(s)`, and the decision answered "2 advisory problem(s) not blocking"
  and delivered nothing. Issue `22f65e5b`.

  John's call, and his reasoning: "the only dude really touching the code and
  subject to credo is the coding agent, who ultimately owns all those changes."
  So on this path the narrowing has nothing to narrow and is dropped.

  The pair below is the whole point. Both turns run against the same tree with
  the same persisted finding and the same `block_changed` configuration, and
  differ only in whether a session is named — so a change that widened *both*
  paths would fail the first assertion rather than pass silently.

  `qa_validation` is the source used because it never writes a ledger row
  (`Run.changeset/2` accepts only compiler/credo/exunit/spex), so it can never
  be stale and freshness cannot quietly explain either outcome. See
  `QaValidationNeverStaleTest`, whose setup this mirrors.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @broken_qa_brief_path ".code_my_spec/qa/9999/brief.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "an agent named without a session blocks on a finding a session would have had demoted" do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    Configurations.get_or_create(scope)

    # Everything else off, so the only source with a persisted problem is the
    # one under test and nothing can block for an unrelated reason.
    {:ok, _} =
      Configurations.update(scope, %{
        compile_warnings: :dont_block,
        exunit: :off,
        credo: :off,
        spex: :off,
        spec_validation: :off,
        qa_validation: :block_changed
      })

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/placeholder.ex"), "defmodule Placeholder do\nend\n")

    {:ok, sync1} = FileSync.sync(scope, base_dir: tmp_dir)
    assert sync1.changed_paths != [], "seed sync must emit changed paths"

    File.mkdir_p!(Path.join(tmp_dir, Path.dirname(@broken_qa_brief_path)))

    File.write!(Path.join(tmp_dir, @broken_qa_brief_path), """
    # QA Brief

    A stub qa brief missing required sections.
    """)

    compile_jsonl = Path.expand(Path.join(@fixture_dir, "compile.jsonl"))

    # Seed: the brief lands as a change this turn, so the finding is recorded
    # and blocks on its own merits. Without this the rest asserts against
    # nothing, which is the failure mode every criterion on story 988 hit.
    assert {:error, seeded, _key} =
             Validation.validate_stop(scope, nil, compile_output_file: compile_jsonl)

    assert seeded =~ "qa_validation", "the finding must be persisted before either turn below"

    # Nothing changes from here. The finding stays on record; only who is
    # asking changes.

    assert {:ok, _result} =
             Validation.validate_stop(scope, nil,
               session_id: "a-session",
               agent_id: "an-agent",
               compile_output_file: compile_jsonl
             ),
           """
           The external path must still demote this. `block_changed` narrows to
           what the session wrote, nothing was attributed to it, and that
           narrowing is the whole of criteria 5100 and 5109. If this blocks,
           the internal rule has widened both paths instead of one.
           """

    assert {:error, internal, _key} =
             Validation.validate_stop(scope, nil,
               agent_id: "an-agent",
               compile_output_file: compile_jsonl
             ),
           """
           An agent running under Alloy was let go over a finding on its own
           tree. It has no session, so nothing can ever be attributed to it and
           `block_changed` would demote every finding it ever makes — including
           the one it just introduced. It owns the checkout it works in.
           """

    assert internal =~ "qa_validation",
           "the internal agent was blocked, but not about the finding: #{internal}"
  end
end
