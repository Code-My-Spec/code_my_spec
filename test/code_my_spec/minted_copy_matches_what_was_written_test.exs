defmodule CodeMySpec.MintedCopyMatchesWhatWasWrittenTest do
  @moduledoc """
  What the server recorded and what is on disk are the same copy.

  The whole reason the id travels *to* the harness rather than back from it is
  that the file and the row should hold one value rather than two derivations of
  one — the failure story 891 exists to end, and its notes list four of them.
  Three moduledocs say so.

  It was not true. Run against a real harness on 2026-09-05, one call produced a
  `.cms_harness.json` saying `6794b0f3` and a row saying `9887632c`. `issue/3`
  looks the presented id up, finds nothing, and mints a fresh one — so a copy
  made by the tool would present the file's id on join, be recognised by
  nothing, and mint a third row.

  Nine spex and a unit test passed over it, because every one asserted the
  tool's *reply* and none compared the reply to what was written. The reply was
  right. The disk was right. They were about different copies.

  The same run wrote no `deploy_key` — `ensure_deploy_key/2` was being handed
  `active_project_id`, a string, where it wants a `%Project{}`, and a `rescue`
  turned the FunctionClauseError into `nil`. A copy that cannot authenticate
  never joins, which is the one thing the key is carried for.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, _} = CodeMySpecSpex.Fixtures.connect_provider(scope, :openai)

    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    n = System.unique_integer([:positive])

    # A host machine for the copy to be made beside.
    root = "/tmp/mint-host-#{n}"
    {:ok, host} = WorkingCopies.issue(scope, nil, root: root, device: device)
    {:ok, _host} = WorkingCopies.report_root(host, root)

    %{scope: scope}
  end

  test "the row and the checkout's own config name the same copy", %{scope: scope} do
    {:ok, copy, _staffed} = WorkingCopies.mint(scope, label: "identity check")

    written =
      copy.root
      |> Path.join(".cms_harness.json")
      |> File.read!()
      |> Jason.decode!()

    assert written["working_copy_id"] == copy.id,
           "the checkout says it is #{written["working_copy_id"]} and the server " <>
             "recorded #{copy.id}. On its next join it presents the file's id, is " <>
             "recognised by nothing, and mints a third row — and everything keyed " <>
             "on the working copy splits across identities describing one directory."

    assert written["harness_id"] == copy.id
  end

  test "the checkout can authenticate as its project", %{scope: scope} do
    {:ok, copy, _staffed} = WorkingCopies.mint(scope, label: "key check")

    written =
      copy.root
      |> Path.join(".cms_harness.json")
      |> File.read!()
      |> Jason.decode!()

    assert is_binary(written["deploy_key"]) and written["deploy_key"] != "",
           "the copy was written without a deploy key, so it can never join. " <>
             "`ensure_deploy_key/2` takes a %Project{} and answers a %Project{}; " <>
             "handing it an id raises, and the version that swallowed that with a " <>
             "rescue shipped copies nothing could authenticate."
  end

  test "the checkout names the project it belongs to", %{scope: scope} do
    {:ok, copy, _staffed} = WorkingCopies.mint(scope, label: "project check")

    written =
      copy.root
      |> Path.join(".cms_harness.json")
      |> File.read!()
      |> Jason.decode!()

    assert written["project_id"] == scope.active_project_id
    assert written["root"] == copy.root
  end
end
