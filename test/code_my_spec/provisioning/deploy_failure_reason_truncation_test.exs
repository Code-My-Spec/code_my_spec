defmodule CodeMySpec.Provisioning.DeployFailureReasonTruncationTest do
  @moduledoc """
  What survives `devops_status`'s truncation of a failed deploy's reason.

  Reported live against MarketMySpec, three times now, in three different
  failure shapes: a kamal-install log, an SSHKit exception, and a bare Ruby
  backtrace. `with_output/2` puts the full raw output — kamal's own
  "Launching command.../INFO [...] Running docker login..." progress noise
  — right after the short reason, and `devops_status` truncates the result
  again on top of that. A single-ended slice (either end) gets some of
  these right and others wrong, because different tools put their one
  useful line in different places; `Truncate.head_and_tail/2` does not have
  to guess which.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Truncate

  test "keeps the tail of a long output, where the real cause lives" do
    reason = "Migration failed (exit 1) — the previous version is still serving."

    output =
      "Launching command with version 733e291f02d9 from new container...\n" <>
        String.duplicate("INFO [85e295e8] some progress line\n", 20) <>
        "ERROR (SSHKit::Command::Failed): Exception while executing on host 178.156.143.212: docker login exited with status 1"

    detail = Steps.with_output(reason, output)

    # The same truncation devops_status itself applies.
    truncated = Truncate.head_and_tail(detail)

    assert truncated =~ "docker login exited with status 1"
  end

  test "a short output is kept in full, unsliced" do
    assert Steps.with_output("Migration failed (exit 1)", "boom") ==
             "Migration failed (exit 1)\n\nboom"
  end

  test "no output at all is just the reason" do
    assert Steps.with_output("Migration failed (exit 1)", "") == "Migration failed (exit 1)"
    assert Steps.with_output("Migration failed (exit 1)", nil) == "Migration failed (exit 1)"
  end
end
