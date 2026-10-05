defmodule CodeMySpec.Validation.SpecsReadyNoteTest do
  @moduledoc """
  `51e319db` — specs_ready is a project-wide latch, so a checkout without the
  commit that made a story's specs go green gets held to it same as the
  checkout that earned it. The latch still blocks by design (story 895's rule
  4, criterion 2406); what changed is that the refusal now says when and on
  what commit the latch was earned, so a reader who does not recognize the
  failure has something concrete to check before assuming they introduced it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Validation

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("specs_ready_note")
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    Configurations.get_or_create(scope)
    # spex defaults to :off for a fresh project (nothing has ever gone green
    # yet to protect) — this test is specifically about a spex finding
    # blocking, so it needs the mode a project earns once it has stories
    # worth holding the line on.
    {:ok, _} = Configurations.update(scope, %{spex: :block_all})

    %{scope: scope, tmp: tmp}
  end

  defp red_spec_on_disk(scope, tmp, story) do
    [criterion | _] = story.criteria
    path = CodeMySpec.BddSpecs.spec_file_path(story, criterion)
    full = Path.join(tmp, path)
    File.mkdir_p!(Path.dirname(full))

    # Minimal but real: the parser only scans the AST for defmodule / a spex
    # call / at least one scenario, never compiles or runs it — see
    # BddSpecs.Parser.validate_structure/1.
    File.write!(full, """
    defmodule Story#{story.number}Spex do
      spex "a feature", criterion: #{criterion.number} do
        scenario "it works" do
        end
      end
    end
    """)

    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    # Enforcement is per-criterion now (story 983): the problem only blocks
    # once the criterion whose path it is has itself latched.

    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: path,
      message: "no match of right hand side value: []",
      severity: :error,
      category: "spex"
    })

    path
  end

  test "a specs_ready finding with no stamp renders no note (pre-existing latches)", %{
    scope: scope,
    tmp: tmp
  } do
    story = story_fixture(scope, %{title: "Old Latch"})
    {:ok, story} = Stories.set_specs_ready(scope, story, true)
    red_spec_on_disk(scope, tmp, story)
    fresh_analysis_runs_fixture(scope)

    assert {:error, reason, _key} = Validation.validate_stop(scope, nil)
    refute reason =~ "specs_ready was earned at"
  end

  test "a specs_ready finding with a stamp names when and on what commit it was earned", %{
    scope: scope,
    tmp: tmp
  } do
    story = story_fixture(scope, %{title: "Fixed Elsewhere"})

    {:ok, story} =
      Stories.set_specs_ready(scope, story, true,
        at: ~U[2026-09-10 12:00:00.000000Z],
        commit: "abc123def4567890"
      )

    red_spec_on_disk(scope, tmp, story)
    fresh_analysis_runs_fixture(scope)

    assert {:error, reason, _key} = Validation.validate_stop(scope, nil)

    assert reason =~ "specs_ready was earned at",
           "expected the orientation note, got:\n#{reason}"

    assert reason =~ "2026-09-10", "expected the earned-at time in the message, got:\n#{reason}"

    assert reason =~ "abc123de",
           "expected the (truncated) commit sha in the message, got:\n#{reason}"

    assert reason =~ "does not have the fix yet" or reason =~ "does not have this commit yet" or
             reason =~ "check whether your checkout already has the commit",
           "expected the message to tell the reader what to check, got:\n#{reason}"
  end

  test "clearing specs_ready wipes the stamp", %{scope: scope} do
    story = story_fixture(scope, %{title: "Reverted"})

    {:ok, story} =
      Stories.set_specs_ready(scope, story, true, at: DateTime.utc_now(), commit: "deadbeef")

    {:ok, cleared} = Stories.set_specs_ready(scope, story, false)

    assert cleared.specs_ready == false
    assert cleared.specs_ready_at == nil
    assert cleared.specs_ready_commit == nil
  end
end
