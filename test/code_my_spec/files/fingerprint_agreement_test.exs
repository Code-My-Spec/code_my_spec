defmodule CodeMySpec.Files.FingerprintAgreementTest do
  @moduledoc """
  A file's fingerprint must not depend on who reported it.

  Two things write `Files.fingerprint`: a harness delivering its scan over the
  channel, and `FileSync` reading the disk here. Problems are stamped with the
  fingerprint of the file as it stood when they were recorded, and
  `reject_superseded/1` drops any finding whose file has moved on since.

  So if those two sources disagree about an unchanged file, recording a finding
  through one and re-syncing through the other silently discards it — the
  finding is "superseded" by a file that never changed. That failure is
  invisible at the point it happens and surfaces later as a stop that does not
  block, which reads as the blocking rule being wrong.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpecSpex.Fixtures

  @path "lib/my_app/accounts.ex"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, @path), "defmodule MyApp.Accounts do\nend\n")

    %{scope: scope, tmp: tmp}
  end

  defp fingerprint(scope) do
    scope
    |> Files.list_files()
    |> Enum.find(&(&1.path == @path))
    |> fingerprint_of()
  end

  defp fingerprint_of(nil), do: nil
  defp fingerprint_of(%{fingerprint: fingerprint}), do: fingerprint

  test "a manifest and a disk sync agree about an unchanged file", %{scope: scope, tmp: tmp} do
    Fixtures.deliver_manifest(scope)
    from_manifest = fingerprint(scope)

    {:ok, _} = FileSync.sync(scope, base_dir: tmp)
    from_disk = fingerprint(scope)

    assert from_manifest != nil, "the manifest should have recorded this file"

    assert from_manifest == from_disk,
           "the bytes did not change, so the fingerprint must not either — a " <>
             "disagreement here supersedes every problem recorded between the two " <>
             "writes, and does it silently"
  end
end
