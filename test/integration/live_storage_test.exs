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

    if is_nil(id) or is_nil(secret) do
      raise "set HETZNER_S3_ACCESS_KEY_ID and HETZNER_S3_SECRET_ACCESS_KEY to run the live storage test"
    end

    credentials = [access_key_id: id, secret_access_key: secret, region: @location]

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

  defp teardown(buckets, credentials) do
    for bucket <- buckets do
      # A bucket with objects in it will not delete, so empty it first.
      case Storage.list_dumps(bucket, credentials, location: @location, prefix: "") do
        {:ok, objects} ->
          for %{key: key} <- objects do
            Storage.delete_object(bucket, key, credentials, location: @location)
          end

        _ ->
          :ok
      end

      Storage.delete_bucket(bucket, credentials, location: @location)
    end

    # Teardown that quietly leaves resources behind bills Sam for our test runs.
    {:ok, left} = Storage.list_buckets(credentials, location: @location)

    for bucket <- buckets, bucket in left do
      IO.warn("live storage test left #{bucket} behind — delete it in the Hetzner console")
    end
  end
end
