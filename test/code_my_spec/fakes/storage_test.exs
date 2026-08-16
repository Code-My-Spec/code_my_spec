defmodule CodeMySpecSpex.Fakes.StorageTest do
  @moduledoc """
  Object storage behaviours, checked through `Provisioning.Storage` rather than
  against the fake directly — the point is that the real client's XML parsing
  meets the fake's XML, since that seam is where a hand-written fake usually
  turns out to be wrong.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpecSpex.Fakes

  setup do
    {:ok, agent} = Agent.start_link(&Fakes.Storage.new/0)
    previous = Application.get_env(:code_my_spec, CodeMySpec.Content.S3Client, [])

    Application.put_env(:code_my_spec, CodeMySpec.Content.S3Client,
      plug: &Fakes.Storage.call(&1, agent)
    )

    on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Content.S3Client, previous)
    end)

    %{
      agent: agent,
      credentials: [
        access_key_id: "fake-id",
        secret_access_key: "fake-secret",
        region: "fsn1"
      ]
    }
  end

  test "a created bucket is in the listing", %{credentials: creds} do
    assert :ok = Storage.ensure_bucket("sams-dumps", creds)
    assert {:ok, names} = Storage.list_buckets(creds)
    assert "sams-dumps" in names
  end

  test "an object put in a bucket comes back out", %{credentials: creds} do
    :ok = Storage.ensure_bucket("sams-dumps", creds)
    :ok = Storage.put_object("sams-dumps", "dumps/prod/one.sql.gz", "PGDMP", creds)

    assert {:ok, "PGDMP"} = Storage.get_object("sams-dumps", "dumps/prod/one.sql.gz", creds)
  end

  # 968 counts dumps under a prefix; a criterion that got the registry's blobs
  # back too would be counting the wrong thing.
  test "listing dumps is filtered by prefix", %{credentials: creds} do
    :ok = Storage.ensure_bucket("sams-stuff", creds)
    :ok = Storage.put_object("sams-stuff", "dumps/prod/one.sql.gz", "a", creds)
    :ok = Storage.put_object("sams-stuff", "dumps/prod/two.sql.gz", "b", creds)
    :ok = Storage.put_object("sams-stuff", "registry/blob", "c", creds)

    assert {:ok, dumps} = Storage.list_dumps("sams-stuff", creds, prefix: "dumps/prod/")
    assert length(dumps) == 2
  end

  test "a deleted object is gone", %{credentials: creds} do
    :ok = Storage.ensure_bucket("sams-dumps", creds)
    :ok = Storage.put_object("sams-dumps", "dumps/prod/one.sql.gz", "a", creds)
    :ok = Storage.delete_object("sams-dumps", "dumps/prod/one.sql.gz", creds)

    assert {:ok, []} = Storage.list_dumps("sams-dumps", creds, prefix: "dumps/")
  end

  # 968/8016 is retention the bucket enforces, not a pruning job. Writing the
  # rule and reading it back is what keeps those two apart.
  test "a lifecycle rule is readable after it is set", %{credentials: creds} do
    :ok = Storage.ensure_bucket("sams-dumps", creds)
    :ok = Storage.put_lifecycle("sams-dumps", 30, creds)

    assert {:ok, days} = Storage.get_lifecycle("sams-dumps", creds)
    assert days == 30
  end
end
