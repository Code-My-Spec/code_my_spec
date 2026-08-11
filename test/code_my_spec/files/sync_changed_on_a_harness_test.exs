defmodule CodeMySpec.Files.SyncChangedOnAHarnessTest do
  @moduledoc """
  `sync_changed/2` against an environment that has no filesystem to walk.

  `Environments.Harness.stream_files/3` answers `{:error, :not_supported_on_harness}`
  rather than an empty stream, and it is right to: scanning is the harness's own
  job — it sends a manifest up, and the server has nothing local to compare.

  What was missing is the caller handling it. `Enum.to_list/1` on an error tuple
  raises `Protocol.UndefinedError`, which crashed the stop-hook handler outright.
  The harness then got no reply and reported "the server did not answer in
  time", so it read as a network or timeout problem — the thing that would have
  said otherwise was the handler that died.

  Found by the recording agent, whose stops had been failing this way, from a
  `Protocol.UndefinedError` in the server log naming
  `{:error, :not_supported_on_harness}` as the value.

  ## The first fix here was half of one

  Handling it meant answering `{:ok, %{total_files: 0}}` — no crash, and the
  refusal folded into an empty scan anyway. `Files.delete_removed/2` then took
  that empty scan as a snapshot and removed every row for the working copy:
  3937 of them plus 452 Problems, on every stop, while the harness re-sent its
  manifest in between and both ends logged success.

  The test below asserted `removed == 0` against that, and passed — because the
  fixture has no rows, so the count it checked could not have come out any other
  way. The assertion was right about the intent and blind to the behaviour.

  So the contract is the refusal now, and the second test gives it something to
  lose first.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync

  setup do
    scope = full_scope_fixture()

    # A harness environment: the type is the whole point, and `cwd` is a path on
    # a machine this server cannot read.
    {:ok, scope: %{scope | environment: Environment.new(:harness, "/somewhere/else")}}
  end

  test "returns rather than raising when the environment cannot be scanned", %{scope: scope} do
    assert {:error, {:cannot_scan, :not_supported_on_harness}} = FileSync.sync_changed(scope)
  end

  test "does not remove records for files it could not see", %{scope: scope} do
    # Rows first. Asserting a zero from a fixture that has nothing to delete is
    # a probe that cannot come back positive, which is how this passed for as
    # long as the defect lived.
    {1, _} = Files.upsert_files(scope, [file_row("lib/my_app/kept.ex")])
    assert length(Files.list_files(scope)) == 1

    assert {:error, {:cannot_scan, :not_supported_on_harness}} = FileSync.sync_changed(scope)

    assert length(Files.list_files(scope)) == 1,
           "a scan that could not run must not be read as an empty working copy"
  end

  defp file_row(path) do
    %{
      path: path,
      role: :implementation,
      mtime: DateTime.utc_now(),
      size: 1,
      fingerprint: "deadbeef"
    }
  end
end
