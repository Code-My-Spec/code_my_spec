defmodule CodeMySpec.Provisioning.FleetStorageTest do
  @moduledoc """
  Write to S3 on the local fleet, and read it back off the wire.

  This is `Content.S3Client` unmodified — real ExAws, real SigV4, real
  path-style addressing — against MinIO instead of Hetzner. `Project.s3_endpoint`
  is what points a publish at a provider, so pointing it at a container needs no
  code change at all: the field that lets a customer pick Hetzner lets a test
  pick this.

  It is the case cassettes were worst at. Three separate defects this epic were
  a *failure* recorded as the story's behaviour — a `NoSuchBucket` from signing
  against the wrong provider, an `InvalidAccessKeyId` from a project with no
  credentials configured, a truncated recording from a detached task — and each
  then replayed green forever without touching a provider again. A real PUT
  against a real implementation cannot be wrong in that direction: either the
  bytes are there afterwards or they are not.

  Excluded by default (`:fleet`):

      docker/fleet/fleet.sh up
      mix test --only fleet
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Content.S3Client

  @moduletag :fleet
  @moduletag timeout: 120_000

  @access_key "cms-fleet"
  @secret_key "cms-fleet-secret"

  setup do
    bucket = "fleet-content-#{System.unique_integer([:positive])}"
    create_bucket(bucket)
    on_exit(fn -> delete_bucket(bucket) end)

    {:ok, bucket: bucket}
  end

  describe "publishing to fleet storage" do
    test "a put lands where a get can find it", %{bucket: bucket} do
      body = Jason.encode!(%{"posts" => [%{"slug" => "fleet", "title" => "Fleet"}]})

      assert :ok =
               S3Client.put_object(bucket, "content.json", body,
                 content_type: "application/json",
                 credentials: credentials()
               )

      # Read back through the same client, not through `mc` — a publish that
      # signs correctly for writing and wrongly for reading is a real shape,
      # and asking a different tool would hide it.
      assert {:ok, ^body} =
               S3Client.get_object(bucket, "content.json", credentials: credentials())
    end

    test "the bytes are really in the bucket, not just accepted", %{bucket: bucket} do
      # Asked of MinIO directly. The client reporting success is the thing under
      # test, so it does not get to be its own witness — that is exactly the
      # mistake a poisoned cassette makes.
      manifest = Jason.encode!(%{"version" => "1.0", "counts" => %{"blog" => 1}})

      assert :ok =
               S3Client.put_object(bucket, "manifest.json", manifest,
                 content_type: "application/json",
                 credentials: credentials()
               )

      assert {out, 0} = mc(["cat", "fleet/#{bucket}/manifest.json"])
      assert out =~ ~s("version")
      assert out =~ ~s("blog")
    end

    test "a wrong secret is refused rather than silently accepted", %{bucket: bucket} do
      # The failure that started all this signed against the wrong provider and
      # got back a plausible-looking error that was then recorded as truth. The
      # useful property is not the message — it is that a bad credential fails
      # at all, which a replayed cassette can no longer tell us.
      bad = Keyword.put(credentials(), :secret_access_key, "not-the-secret")

      assert {:error, _} =
               S3Client.put_object(bucket, "content.json", "{}",
                 content_type: "application/json",
                 credentials: bad
               )
    end
  end

  defp credentials do
    [
      access_key_id: @access_key,
      secret_access_key: @secret_key,
      # Hetzner is S3-compatible but not S3, and needs path-style addressing —
      # a virtual-host-style request reaches a bucket that does not exist rather
      # than failing usefully. MinIO has the same property, so the fleet
      # exercises the setting rather than tolerating either value.
      host: "127.0.0.1",
      scheme: "http://",
      port: 9000,
      region: "us-east-1"
    ]
  end

  defp create_bucket(bucket) do
    {_, 0} = mc(["mb", "--ignore-existing", "fleet/#{bucket}"])
  end

  defp delete_bucket(bucket) do
    mc(["rb", "--force", "fleet/#{bucket}"])
  end

  # Through the MinIO container's own client, so this needs nothing installed
  # on the machine running the suite.
  #
  # Credentials come in as `MC_HOST_<alias>` rather than from `mc alias set`.
  # The image does configure a `local` alias — the one the compose healthcheck
  # asks with — but it is anonymous, which is enough to answer "are you ready"
  # and not enough to make a bucket. Passing them per-invocation also leaves no
  # state in the container for the next run to inherit.
  defp mc(args) do
    System.cmd(
      "docker",
      ["exec", "-e", "MC_HOST_fleet=#{mc_host()}", "cms-fleet-minio-1", "mc"] ++ args,
      stderr_to_stdout: true
    )
  end

  defp mc_host, do: "http://#{@access_key}:#{@secret_key}@127.0.0.1:9000"
end
