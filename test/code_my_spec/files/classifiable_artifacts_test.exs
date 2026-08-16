defmodule CodeMySpec.Files.ClassifiableArtifactsTest do
  @moduledoc """
  Every file a requirement gates on has to be a file the classifier recognises.

  Five times now a requirement has demanded an artifact that `classify/1` had
  never heard of. Each cost most of a drill, and each presented identically and
  misleadingly: the agent writes the file, the graph does not move, and it
  concludes the file watcher is broken. Twice it spent its remaining time trying
  to revive a watcher that was working perfectly — scanning every forty-five
  seconds, the server accepting every manifest.

  The tell is always the same and always missed: the scan finds a *constant*
  number of files while the agent keeps writing. An unclassified file is not
  synced, and a file that is not synced cannot be distinguished from one that
  was never written.

    * `.code_my_spec/personas/<slug>/summary.md`, `sources.md`
    * `.code_my_spec/credo_checks/**/*.ex`
    * `test/support/fixtures/<app>_spex_fixtures.ex`
    * `.code_my_spec/qa/plan.md`
    * `.code_my_spec/qa/journey_result.md`

  So: name the artifacts, and assert the classifier has a role for each. Adding
  a requirement that reads a new path fails here, at the moment the path is
  introduced, rather than in a drill log an hour later.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Paths

  # Paths a requirement or agent task reads to decide whether it is satisfied.
  # A directory entry stands for the files inside it, so it is probed with a
  # representative name.
  @gated_artifacts [
    {Paths.proposal_path(), "architecture proposal"},
    {Paths.decisions_index(), "ADR index"},
    {Path.join(Paths.decisions_dir(), "0001-some-decision.md"), "an ADR"},
    {Paths.qa_plan(), "QA plan"},
    {Paths.qa_journey_plan(), "QA journey plan"},
    {Paths.qa_journey_result(), "QA journey result"},
    {Path.join(Paths.credo_checks_framework_dir(), "spex_denied_calls.ex"),
     "framework credo check"},
    {Path.join(Paths.credo_checks_local_dir(), "my_app_spex_denies.ex"), "project credo check"},
    {Path.join([Paths.knowledge_dir(), "bdd", "spex", "index.md"]), "project BDD plan"},
    {Path.join(Paths.personas_dir(), "some-slug/summary.md"), "persona summary"},
    {Path.join(Paths.personas_dir(), "some-slug/sources.md"), "persona sources"},
    {"test/support/fixtures/my_app_spex_fixtures.ex", "spex fixtures bridge"},
    {Path.join(Paths.integrations_dir(), "stripe.md"), "an integration spec"},
    # A sibling of `integrations/`, not a file inside it, so the directory
    # prefix rule never claimed it — the sixth instance of this exact bug, and
    # the one this list existed to catch. `QaIntegrationPlan.check_index/1`
    # gates on it and writing it is half the task's done signal.
    {Paths.integrations_index(), "integration index"},
    # The script each integration spec names, one indirection past the spec.
    # `41406ceb`: classifying the specs closed the hole for their contents and
    # left this open — `check_one_verify_script/2` parses the path out of the
    # spec and asserts the file exists, so an agent creating the very script
    # that satisfies the check moved no fingerprint. Seventh instance, and the
    # first where the gated path is named by *another* gated file rather than
    # hard-coded, which is why reading the checker was not enough to spot it.
    {Path.join(Paths.qa_scripts_dir(), "verify_github.sh"), "an integration verify script"},
    {"mix.exs", "mix.exs"},
    {".credo.exs", ".credo.exs"},
    {"CLAUDE.md", "CLAUDE.md"},
    {Path.join(Paths.base_dir(), "AGENTS.md"), "AGENTS.md"}
  ]

  for {path, description} <- @gated_artifacts do
    test "#{description} (#{path}) classifies to a role" do
      assert {_path, role} = Scanner.classify(unquote(path)),
             """
             `#{unquote(path)}` is read by a requirement but the classifier has no
             role for it, so it never syncs — and on a server with no working copy
             the requirement reports it missing while it sits on the agent's disk.

             Add a clause to `Scanner.classify/1`, a role to `Files.File`, and a
             Postgres enum migration. The harness runs this same `Scanner`, so
             there is nothing to port — `CmsHarness.Sync` calls
             `Scanner.observe/2` directly and says so.
             """

      assert is_atom(role)
    end
  end
end
