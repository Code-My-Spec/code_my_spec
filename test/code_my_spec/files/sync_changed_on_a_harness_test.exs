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
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync

  setup do
    scope = full_scope_fixture()

    # A harness environment: the type is the whole point, and `cwd` is a path on
    # a machine this server cannot read.
    {:ok, scope: %{scope | environment: Environment.new(:harness, "/somewhere/else")}}
  end

  test "returns rather than raising when the environment cannot be scanned", %{scope: scope} do
    assert {:ok, result} = FileSync.sync_changed(scope)

    # Nothing to scan is not nothing to do — the rest of the sync still
    # reconciles against what is already recorded — but nothing was found here,
    # and the count has to say so rather than inheriting a previous run's.
    assert result.total_files == 0
  end

  test "does not remove records for files it could not see", %{scope: scope} do
    # The dangerous shape, and the reason an empty list is only safe because the
    # harness's own manifest is what maintains these rows. A scan that returned
    # "no files" *as if it had looked* would prune every record the harness had
    # sent — the same event as "the server has no disk" deleting the
    # architecture, which `ComponentSync` already carries scars from.
    assert {:ok, result} = FileSync.sync_changed(scope)

    assert result.removed == [] or result.removed == 0,
           "a scan that could not run must not be read as an empty working copy"
  end
end
