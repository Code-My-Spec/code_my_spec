defmodule CodeMySpec.Provisioning.ContentPublishingTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.ContentPublishing
  alias CodeMySpec.Users.Scope

  defp scope(overrides \\ %{}) do
    project =
      struct(
        Project,
        Map.merge(
          %{
            content_bucket: "sams-content",
            client_api_url: "https://sams-site.com",
            deploy_key: "dk_live"
          },
          overrides
        )
      )

    %Scope{active_project: project}
  end

  defp published, do: %{sync_id: "s1", site_url: "https://sams-site.com"}

  defp fetching(status, body) do
    fn _base, _path -> {:ok, %{status: status, body: body}} end
  end

  describe "ensure_publishable/1" do
    test "passes when the trigger has everywhere to go" do
      assert :ok = ContentPublishing.ensure_publishable(scope())
    end

    # Criterion 8058. Sync is trigger-only — no reconciliation pass, no retry
    # sweep. An unconfigured trigger means the content sits in the bucket and
    # the site never learns about it, which is indistinguishable from success
    # unless someone checks.
    test "names each missing field rather than saying 'not configured'" do
      assert {:error, {:not_publishable, missing}} =
               ContentPublishing.ensure_publishable(scope(%{client_api_url: nil, deploy_key: ""}))

      assert :client_api_url in missing
      assert :deploy_key in missing
      refute :content_bucket in missing
    end

    test "a blank string counts as missing, not as configured" do
      assert {:error, {:not_publishable, [:content_bucket]}} =
               ContentPublishing.ensure_publishable(scope(%{content_bucket: ""}))
    end

    test "no active project is reported rather than crashing" do
      assert {:error, {:not_publishable, [:active_project]}} =
               ContentPublishing.ensure_publishable(%Scope{})
    end
  end

  describe "run/2 — done means rendered" do
    # Criteria 8036 and 8039: the step is finished when a real post has been
    # fetched back from the deployed site with its content in the body.
    test "reaches :rendered and stamps when it was proven" do
      result =
        ContentPublishing.run(scope(),
          publish: fn _ -> {:ok, published()} end,
          fetch: fetching(200, "<h1>hello world</h1>"),
          path: "/blog/hello-world",
          expect: "hello world"
        )

      assert result.state == :rendered
      assert %DateTime{} = result.proven_at
      assert result.render.body_contains
    end

    # Criterion 8038: content that does not verify is left unserved. A 200
    # alone would pass against a catch-all route or a styled 404, so the body
    # has to be checked too.
    test "a 200 whose body lacks the content is not rendered" do
      result =
        ContentPublishing.run(scope(),
          publish: fn _ -> {:ok, published()} end,
          fetch: fetching(200, "<h1>Page not found</h1>"),
          path: "/blog/hello-world",
          expect: "hello world"
        )

      assert result.state == :not_rendered
      assert result.proven_at == nil
      refute result.render.body_contains
      assert result.reason =~ "not served"
    end

    test "a non-200 is not rendered either" do
      result =
        ContentPublishing.run(scope(),
          publish: fn _ -> {:ok, published()} end,
          fetch: fetching(404, ""),
          path: "/blog/hello-world",
          expect: "hello world"
        )

      assert result.state == :not_rendered
      assert result.reason =~ "404"
    end
  end

  describe "run/2 — a lost trigger" do
    # Criterion 8058: reported, not swallowed.
    test "refuses to publish at all when the trigger has nowhere to go" do
      result =
        ContentPublishing.run(scope(%{client_api_url: nil}),
          publish: fn _ -> flunk("published despite having no trigger target") end,
          fetch: fetching(200, "hello"),
          path: "/blog/x",
          expect: "hello"
        )

      assert result.state == :trigger_failed
      assert result.reason =~ "client_api_url"
      assert result.reason =~ ~r/trigger-only/
    end

    # The pipeline reports a failed trigger and a failed S3 write through the
    # same {:error, %{message:}} shape, so the message is the only thing that
    # distinguishes them. Filing a lost trigger as a storage problem would
    # send someone to the wrong provider.
    test "a trigger failure from the pipeline is classified as a trigger failure" do
      result =
        ContentPublishing.run(scope(),
          publish: fn _ -> {:error, %{message: "Client pull trigger failed: :econnrefused"}} end,
          path: "/blog/x",
          expect: "hello"
        )

      assert result.state == :trigger_failed
      assert result.reason =~ ~r/trigger/i
    end

    test "an S3 failure is not misfiled as a trigger failure" do
      result =
        ContentPublishing.run(scope(),
          publish: fn _ -> {:error, %{message: "S3 write failed: :timeout"}} end,
          path: "/blog/x",
          expect: "hello"
        )

      assert result.state == :publish_failed
    end
  end

  describe "verify_render/2" do
    test "an unreachable site is not rendered rather than a crash" do
      assert {:error, {:not_rendered, render}} =
               ContentPublishing.verify_render(published(),
                 fetch: fn _, _ -> {:error, :nxdomain} end,
                 path: "/blog/x",
                 expect: "hello"
               )

      refute render.body_contains
    end
  end
end
