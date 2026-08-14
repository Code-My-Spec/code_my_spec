defmodule CmsHarness.UnclassifiedReportingTest do
  @moduledoc """
  The harness has to say which files it walked past.

  Three drills in a row diagnosed a classification gap as a dead file watcher.
  The tell was always the same: the scan reports a constant file count while the
  agent keeps writing, because an unclassified file is dropped in silence. Two
  agents spent their remaining time trying to revive watchers that were scanning
  every forty-five seconds with every manifest accepted; one filed it as a
  critical framework issue.

  The first version of this fix logged at `:debug`. The release runs prod
  config, where `:debug` is filtered — so the diagnostic was invisible in the
  only environment that needed it, which is worse than not having it: an absent
  line reads as "nothing was skipped".
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CmsHarness.Sync

  setup do
    root =
      CodeMySpec.TempFile.dir("cms_harness_unclassified")

    File.mkdir_p!(Path.join(root, "test/support"))

    # `config/test.exs` runs Logger at :warning, which drops these lines before
    # `capture_log` ever sees them — the same shape as the bug under test, one
    # layer up. Raise the real level, not just the capture level.
    previous = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: previous)
      File.rm_rf(root)
    end)

    on_exit(fn -> :persistent_term.erase({Sync, :unclassified, "p1"}) end)
    %{root: root}
  end

  test "an unclassified file is named at a level the release actually logs", %{root: root} do
    File.write!(Path.join(root, "test/support/random_helper.ex"), "not a role we know\n")

    log = capture_log([level: :info], fn -> Sync.report_skipped(root) end)

    assert log =~ "match no role",
           "at :debug this never appears in a release, and an absent line reads " <>
             "as evidence that nothing was skipped"

    assert log =~ "not the watcher",
           "the message has to name the misdiagnosis it exists to prevent"
  end

  test "it does not repeat itself on every scan", %{root: root} do
    File.write!(Path.join(root, "test/support/random_helper.ex"), "x\n")

    assert capture_log([level: :info], fn -> Sync.report_skipped(root) end) =~
             "match no role"

    assert capture_log([level: :info], fn -> Sync.report_skipped(root) end) == "",
           "a sync every ninety seconds must not restate an unchanged list"
  end

  test "a newly unclassified file breaks the silence", %{root: root} do
    assert capture_log([level: :info], fn -> Sync.report_skipped(root) end) =~
             "now has a role"

    File.write!(Path.join(root, "test/support/another_helper.ex"), "x\n")

    assert capture_log([level: :info], fn -> Sync.report_skipped(root) end) =~
             "another_helper.ex",
           "the moment a file stops being tracked is exactly when this must speak"
  end
end
