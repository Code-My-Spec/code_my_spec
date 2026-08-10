defmodule CodeMySpec.LiveStorageTest do
  @moduledoc """
  Proves `Provisioning.Storage` against real Hetzner object storage.

  Excluded by default (`:live`). Needs `HETZNER_S3_ACCESS_KEY_ID` and
  `HETZNER_S3_SECRET_ACCESS_KEY` — Hetzner mints those in the console only, so
  they cannot be created here.

  Every assertion in story 968 is about something that either exists in Sam's
  account or does not: a bucket, an object, a lifecycle rule. A stubbed S3
  proves the code calls a function, not that Hetzner accepted it — and the two
  came apart already on this story (a 409 for a bucket you own reads as
  failure until you see one).
  """
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 300_000

  alias CodeMySpec.Provisioning.Storage

  @location "fsn1"

  setup_all do
    id = System.get_env("HETZNER_S3_ACCESS_KEY_ID")
    secret = System.get_env("HETZNER_S3_SECRET_ACCESS_KEY")

    credentials = credentials!(id, secret)

    # Distinct per environment on purpose — criterion 8012 is exactly this.
    project = %{name: "cms-live-store"}
    prod = Storage.bucket_name(project, "prod")
    uat = Storage.bucket_name(project, "uat")

    on_exit(fn -> teardown([prod, uat], credentials) end)

    %{credentials: credentials, project: project, prod: prod, uat: uat}
  end

  # A generic fallback name would be *shared* across every unnamed project,
  # so the absence of one has to be loud.
  test "a project with no name cannot silently share a bucket with another" do
    assert_raise ArgumentError, ~r/no name/, fn ->
      Storage.bucket_name(%{}, "prod")
    end
  end

  test "buckets land in Sam's own account, one per environment", ctx do
    assert {:ok, prod} = Storage.ensure_bucket(ctx.prod, ctx.credentials, location: @location)
    assert {:ok, _uat} = Storage.ensure_bucket(ctx.uat, ctx.credentials, location: @location)

    assert prod.owner == "user"
    assert prod.location =~ ctx.prod

    IO.puts("\n  buckets    -> #{ctx.prod}, #{ctx.uat}")

    {:ok, buckets} = Storage.list_buckets(ctx.credentials, location: @location)
    assert ctx.prod in buckets
    assert ctx.uat in buckets

    # Criterion 7965: running the step twice leaves one of everything. S3
    # answers an existing bucket with a 409, so this is where "converges"
    # and "fails on the second run" actually differ.
    assert {:ok, _} = Storage.ensure_bucket(ctx.prod, ctx.credentials, location: @location)

    {:ok, again} = Storage.list_buckets(ctx.credentials, location: @location)
    assert Enum.count(again, &(&1 == ctx.prod)) == 1
  end

  test "an upload to one environment leaves the other untouched", ctx do
    {:ok, _} = Storage.ensure_bucket(ctx.prod, ctx.credentials, location: @location)
    {:ok, _} = Storage.ensure_bucket(ctx.uat, ctx.credentials, location: @location)

    key = "#{Storage.dumps_prefix()}probe.txt"

    assert :ok = Storage.put_object(ctx.uat, key, "uat-only", ctx.credentials)
    assert {:ok, "uat-only"} = Storage.get_object(ctx.uat, key, ctx.credentials)

    IO.puts("  isolation  -> wrote #{key} to #{ctx.uat}")

    # The whole point of separate buckets: the test upload is not sitting in
    # production waiting to be mistaken for real data.
    {:ok, prod_dumps} = Storage.list_dumps(ctx.prod, ctx.credentials, location: @location)

    refute Enum.any?(prod_dumps, &(&1.key == key)),
           "a UAT upload appeared in the production bucket"
  end

  test "retention is a rule the bucket enforces, not a job we hope runs", ctx do
    {:ok, _} = Storage.ensure_bucket(ctx.prod, ctx.credentials, location: @location)

    assert :ok = Storage.put_lifecycle(ctx.prod, 14, ctx.credentials, location: @location)

    # Read it back from Hetzner rather than trusting the write — criterion
    # 8016 is about retention that is actually in force.
    assert {:ok, 14} = Storage.get_lifecycle(ctx.prod, ctx.credentials, location: @location)

    IO.puts("  retention  -> 14 days, enforced by bucket lifecycle")
  end

  test "dumps are listed with a size and a date", ctx do
    {:ok, _} = Storage.ensure_bucket(ctx.prod, ctx.credentials, location: @location)

    key = "#{Storage.dumps_prefix()}prod-20260730T000000Z.sql.gz"
    :ok = Storage.put_object(ctx.prod, key, "-- dump\nSELECT 1;\n", ctx.credentials)

    {:ok, dumps} = Storage.list_dumps(ctx.prod, ctx.credentials, location: @location)
    dump = Enum.find(dumps, &(&1.key == key))

    assert dump, "expected the dump we just uploaded to be listed"
    assert dump.size > 0, "a zero-byte dump is not a backup"
    assert is_binary(dump.taken_at) and dump.taken_at != ""

    IO.puts("  dumps      -> #{dump.key} (#{dump.size} bytes, #{dump.taken_at})")
  end

  # S3 refuses to delete a bucket that still holds objects, and `delete_bucket`
  # went straight to the delete and retried the refusal eight times. Every
  # bucket teardown had ever been asked to remove was empty, so it looked like
  # it worked — until the registry's, which holds the image layers and is
  # never empty. A project's registry bucket could not be deleted at all, and
  # the next drill refused to start on residue its own teardown was incapable
  # of clearing.
  #
  # This test's own helper knew to empty first. That knowledge belonged in
  # `delete_bucket/3`, which is what teardown outside this file calls.
  test "a bucket with objects in it still deletes", ctx do
    {:ok, _} = Storage.ensure_bucket(ctx.uat, ctx.credentials, location: @location)

    for n <- 1..3 do
      :ok = Storage.put_object(ctx.uat, "layers/blob-#{n}", "content-#{n}", ctx.credentials)
    end

    # The return value, not the listing: S3 accepting the DELETE is the
    # behaviour that changed. Before this, the bucket was non-empty, every one
    # of the eight attempts was refused, and this came back `{:error, _}`.
    assert :ok = Storage.delete_bucket(ctx.uat, ctx.credentials, location: @location)

    # And it really is gone — polled, because Ceph's bucket listing lags its
    # own deletes by up to half a minute. Asserting on one immediate listing
    # fails against a bucket that has genuinely been removed.
    assert_bucket_gone(ctx.uat, ctx.credentials, 30)

    IO.puts("  non-empty  -> deleted #{ctx.uat} with 3 objects in it")
  end

  defp assert_bucket_gone(bucket, credentials, attempts) do
    {:ok, buckets} = Storage.list_buckets(credentials, location: @location)

    gone?(bucket, bucket in buckets, credentials, attempts)
  end

  defp gone?(_bucket, false, _credentials, _attempts), do: :ok

  defp gone?(bucket, true, credentials, attempts) when attempts > 1 do
    Process.sleep(1_000)
    assert_bucket_gone(bucket, credentials, attempts - 1)
  end

  defp gone?(bucket, true, _credentials, _attempts) do
    flunk("#{bucket} was still listed thirty seconds after it was deleted")
  end

  # Hetzner mints these in the console only, so a run without them cannot be
  # made to work by anything here — it has to stop and say which two are
  # missing. By clause rather than by `if`, which the framework's own check
  # rejects in a test file.
  defp credentials!(id, secret) when is_binary(id) and is_binary(secret) do
    [access_key_id: id, secret_access_key: secret, region: @location]
  end

  defp credentials!(_id, _secret) do
    raise "set HETZNER_S3_ACCESS_KEY_ID and HETZNER_S3_SECRET_ACCESS_KEY to run the live storage test"
  end

  defp teardown(buckets, credentials) do
    for bucket <- buckets do
      # Emptying first is `delete_bucket/3`'s job now — see the test above for
      # why it had to become so.
      Storage.delete_bucket(bucket, credentials, location: @location)
    end

    # Teardown that quietly leaves resources behind bills Sam for our test runs.
    {:ok, left} = Storage.list_buckets(credentials, location: @location)

    for bucket <- buckets, bucket in left do
      IO.warn("live storage test left #{bucket} behind — delete it in the Hetzner console")
    end
  end
end
