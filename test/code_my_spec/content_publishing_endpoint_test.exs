defmodule CodeMySpec.ContentPublishingEndpointTest do
  @moduledoc """
  A project's S3 credentials are signed against the provider they belong to.

  The fields are named `aws_*`, but they are just S3 credentials — and
  provisioning's own storage is Hetzner from end to end: the server step, the
  registry, backups and the object-storage step all use it. Content publishing
  was the one path with no way to say so, so ExAws defaulted to Amazon and a
  project set up entirely through our own flow could not publish to the buckets
  that flow had just created for it. What the customer saw was `NoSuchBucket`
  naming a bucket they had definitely made.

  A blank endpoint still means Amazon, which is what every project did before
  this existed.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects

  setup do
    {:ok, scope: full_scope_fixture()}
  end

  describe "the endpoint is a project setting" do
    test "it can be set and read back", ctx do
      {:ok, project} =
        Projects.update_project(ctx.scope, ctx.scope.active_project, %{
          s3_endpoint: "fsn1.your-objectstorage.com"
        })

      assert project.s3_endpoint == "fsn1.your-objectstorage.com"
    end

    test "a project that never sets one keeps nil, which means Amazon", ctx do
      assert ctx.scope.active_project.s3_endpoint == nil
    end
  end

  # `endpoint_config/1` is private, so these go through the public seam that
  # actually matters: what a publish would sign against. Asserting the derived
  # ExAws options directly would be asserting the implementation.
  describe "what the credentials carry" do
    test "a bare host is turned into host, scheme and port", ctx do
      config = credentials_for(ctx.scope, "fsn1.your-objectstorage.com")

      assert config[:host] == "fsn1.your-objectstorage.com"
      assert config[:scheme] == "https://"
      assert config[:port] == 443
    end

    # Pasting the URL from a provider's console is the obvious thing to do, and
    # signing `https://` into a host that already has one produces a URL with
    # the scheme twice.
    test "a pasted URL is accepted and split", ctx do
      config = credentials_for(ctx.scope, "https://fsn1.your-objectstorage.com")

      assert config[:host] == "fsn1.your-objectstorage.com"
      assert config[:scheme] == "https://"
    end

    test "no endpoint means no host override, so ExAws goes to Amazon", ctx do
      config = credentials_for(ctx.scope, nil)

      refute Keyword.has_key?(config, :host)
    end
  end

  # Mirrors `ContentPublishing.aws_credentials/1` through the only public path
  # that exposes it: a project's stored settings become the S3 request config.
  defp credentials_for(scope, endpoint) do
    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{
        aws_access_key_id: "key",
        aws_secret_access_key: "secret",
        aws_region: "fsn1",
        s3_endpoint: endpoint
      })

    CodeMySpec.ContentPublishing.s3_credentials(project)
  end
end
