defmodule CodeMySpec.Integration.InternalAgentOwnsItsTreeTest do
  @moduledoc """
  What an agent with no session is answerable for: the files it edited, and
  those only.

  `block_changed` narrows a source to the files the stopping agent wrote, and it
  learned that from PostToolUse — which an agent under Alloy never fires. Its
  changed set was therefore empty forever, and the internal path got the answer
  wrong twice in one night from guessing around that hole:

    * Empty set, no widening: a real agent created a module with no `@moduledoc`
      and was told "2 advisory problem(s) not blocking". Issue `22f65e5b`.
    * Widened to the whole tree: a product agent on the war epic was handed 160
      pre-existing credo findings 70ms after its first turn, and spent every
      turn after that running `mix credo` on somebody else's refactor.

  Neither was a policy question. Both came from not recording what the agent had
  edited. `FileEdits.track_agent_edit/2` records it now, on every `write` and
  `edit` it makes, so this path answers what the session path has always
  answered — and the role table that stood in for it is gone.

  One thing did change afterwards, and it is the `block_all` case below rather
  than the `block_changed` ones: John, 2026-10-04 and issue 48f4eada — *task
  evaluation judges the whole copy, like promotion* — retired attribution as an
  override. It used to run after the mode partition and demote whatever was
  left, so an agent that had edited nothing was excused even from a source the
  project had set to `block_all`. `8ccd19097` removed that pass.

  The distinction is worth keeping straight, because the two look alike and are
  not. `block_changed` is a mode the project chooses, and it narrows by changed
  files legitimately, before attribution is consulted. Attribution was an
  invisible second pass that could overrule the choice. Only the second is gone.

  `qa_validation` is the source under test because it never writes a ledger row
  (`Run.changeset/2` accepts only compiler/credo/exunit/spex), so it can never
  be stale and freshness cannot quietly explain any of these outcomes. It also
  defaults to `block_changed`, which is what makes the mode-plain tests here
  meaningful and the one `block_all` test below a deliberate exception.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @broken_qa_brief_path ".code_my_spec/qa/9999/brief.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  # `spex: :off` above now stops `spex_stale` from being requested at all
  # (`@config_gated_analyzers`), so this fixture is never actually consumed
  # in this file — kept passed through anyway, harmlessly, rather than
  # stripped from seven call sites for a test file that has nothing to say
  # about spex either way; every `validate_stop` here is about
  # qa_validation attribution.
  @spex_output_file Path.expand("test/fixtures/validation/spex_green.jsonl")

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp seeded_scope do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")
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
             stop(scope,
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             )

    assert seeded =~ "qa_validation", "the finding must be persisted before any turn below"

    {scope, compile_jsonl}
  end

  test "an agent that edited the file is answerable for it" do
    {scope, compile_jsonl} = seeded_scope()

    FileEdits.track_agent_edit("an-agent", @broken_qa_brief_path)

    assert {:error, reason, _key} =
             stop(scope,
               agent_id: "an-agent",
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             ),
           """
           The agent edited the file this finding is about and was let go. An
           agent with no session records its edits through FileEdits precisely
           so this case can be told from the one below.
           """

    assert reason =~ "qa_validation"
  end

  test "an agent that edited nothing is answerable for nothing" do
    {scope, compile_jsonl} = seeded_scope()

    assert {:ok, _result} =
             stop(scope,
               agent_id: "an-idle-agent",
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             ),
           """
           An agent that has edited nothing was blocked on a pre-existing
           finding. This is the war-epic product agent's case: it had touched no
           file, and being handed the tree's backlog made it spend every turn on
           work that was never its own.
           """
  end

  test "one agent's edits do not make another agent answerable" do
    {scope, compile_jsonl} = seeded_scope()

    FileEdits.track_agent_edit("the-editor", @broken_qa_brief_path)

    assert {:ok, _result} =
             stop(scope,
               agent_id: "the-bystander",
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             ),
           """
           A finding was attributed to an agent that did not make the edit. Two
           agents share a working copy routinely, and attribution that leaks
           between them is the same failure as no attribution at all.
           """
  end

  test "a block_all source blocks even when the agent did not touch the file" do
    {scope, compile_jsonl} = seeded_scope()

    # `block_all` ignores changed files by design, so the mode partition leaves
    # the finding blocking and the agent's changed set is never consulted. This
    # test asserted the opposite until 48f4eada/8ccd19097: attribution ran after
    # the mode partition on whatever was left, so an agent that had edited
    # nothing was excused even from a source set to `block_all`.
    #
    # The distinction that survives, and the reason the five tests around this
    # one are untouched: `block_changed` is a mode the project chooses, and it
    # narrows by changed files legitimately. Attribution was different — it
    # overrode the chosen mode invisibly, which is what retired it.
    {:ok, _} = Configurations.update(scope, %{qa_validation: :block_all})

    assert {:error, reason, _key} =
             stop(scope,
               agent_id: "an-idle-agent",
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             ),
           """
           A block_all finding on a file this agent never touched was demoted.
           `block_all` means block: edit tracking narrows `block_changed`, and it
           is not consulted for a source set to block everything.
           """

    assert reason =~ "qa_validation"
  end

  test "a block_all source still blocks the agent that did touch the file" do
    {scope, compile_jsonl} = seeded_scope()

    {:ok, _} = Configurations.update(scope, %{qa_validation: :block_all})
    FileEdits.track_agent_edit("an-agent", @broken_qa_brief_path)

    assert {:error, reason, _key} =
             stop(scope,
               agent_id: "an-agent",
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             ),
           "the agent broke it and was let go — demotion must not swallow its own findings"

    assert reason =~ "qa_validation"
  end

  test "the external session path is untouched by any of this" do
    {scope, compile_jsonl} = seeded_scope()

    assert {:ok, _result} =
             stop(scope,
               session_id: "a-session",
               agent_id: "an-agent",
               compile_output_file: compile_jsonl,
               spex_output_file: @spex_output_file
             ),
           """
           The external path must still demote a finding nothing was attributed
           to. That narrowing is the whole of criteria 5100 and 5109; if this
           blocks, the agent path has been wired into the session path rather
           than beside it.
           """
  end

  # A stop never starts or ingests analysis (John, 2026-10-04): the recorded
  # outputs land as completed runs first, and the stop reads what they found.
  defp stop(scope, opts),
    do: Validation.validate_stop(scope, nil, CodeMySpecSpex.Fixtures.land_outputs(scope, opts))
end
