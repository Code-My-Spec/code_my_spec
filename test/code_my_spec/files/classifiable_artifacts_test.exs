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

             Add a clause to `Scanner.classify/1`, a role to `Files.File`, a
             Postgres enum migration, and port all of it to cms_scan so the harness
             classifies it the same way.
             """

      assert is_atom(role)
    end
  end
end
