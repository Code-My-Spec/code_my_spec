defmodule CodeMySpec.Provisioning.ContentWidgetProofsTest do
  @moduledoc """
  What the content step records, which is what the page can show.

  It used to collapse everything into `%{kind: "content", location: "published
  and rendered"}` while `ContentPublishing.run/2` underneath computed the whole
  answer: which objects landed in whose bucket, what the live site returned for
  the post's path, when it was proven. That is why every criterion in story 972
  selected on markup that could not exist — there was nothing to render.

  `inbound_proof` and `restore_proof` are the shape followed here: the claim in
  `kind`, its subject in `location`, the evidence in `identifier`.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.Steps

  @published %{
    site_url: "https://sam.example.com",
    objects: [
      %{key: "posts/hello.html", bucket: "sam-uat"},
      %{key: "index.html", bucket: "sam-uat"}
    ]
  }

  setup do
    scope = full_scope_fixture()

    # `ensure_publishable/1` refuses to start without these, and rightly so —
    # a trigger-only pipeline with no client would publish into silence. The
    # step under test is the one after that gate.
    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{
        content_bucket: "sam-uat",
        client_api_url: "https://sam.example.com/api",
        deploy_key: "dk_test"
      })

    {:ok, scope: %{scope | active_project: project}}
  end

  defp run_content(scope, opts) do
    Steps.run(
      :content,
      scope,
      Keyword.merge(
        [
          path: "/blog/hello",
          expect: "Hello",
          publish: fn _scope -> {:ok, @published} end,
          now: fn -> ~U[2026-08-08 12:00:00Z] end
        ],
        opts
      )
    )
  end

  defp find(resources, kind), do: Enum.filter(resources, &(&1.kind == kind))

  describe "a publish that rendered" do
    setup ctx do
      {:ok, resources} =
        run_content(ctx.scope, fetch: fn _base, _path -> {:ok, %{status: 200, body: "Hello"}} end)

      {:ok, resources: resources}
    end

    # 8036: the post renders at its address on the deployed site.
    test "records what the live site returned, and where", ctx do
      assert [proof] = find(ctx.resources, "content_proof")

      assert proof.location == "/blog/hello"
      assert proof.identifier =~ "status=200"
      assert proof.identifier =~ "title_present=true"
      assert proof.identifier =~ "proven_at=2026-08-08"
    end

    # 8035: the published files are in Sam's storage. One resource per object,
    # because a single summary line cannot say whose bucket each landed in.
    test "records every object and its bucket", ctx do
      objects = find(ctx.resources, "content_object")

      assert length(objects) == 2
      assert Enum.all?(objects, &(&1.identifier =~ "owner=user"))
      assert Enum.all?(objects, &(&1.identifier =~ "bucket=sam-uat"))
      assert Enum.any?(objects, &(&1.location == "posts/hello.html"))
    end
  end

  describe "a publish that uploaded and then did not render" do
    # 8058 and 8038 both turn on this: the files are there and the post is not
    # being served. `run/2` used to report `published: nil` here, because
    # `verify_render/2` failed as a `with` else-branch where `published` was
    # out of scope — so the one fact that distinguishes this from a publish
    # that never happened was discarded a layer below the step.
    test "keeps the objects and says the upload happened", ctx do
      assert {:error, reason, resources} =
               run_content(ctx.scope,
                 fetch: fn _base, _path -> {:ok, %{status: 200, body: "a styled 404"}} end
               )

      assert reason =~ "published but not served"

      assert [failure] = find(resources, "content_failure")
      assert failure.identifier =~ "state=not_rendered"
      assert failure.identifier =~ "objects_uploaded=true"

      assert length(find(resources, "content_object")) == 2,
             "the files that did land are the point — they are what makes this not a failed upload"
    end

    test "says so when the publish itself never happened", ctx do
      assert {:error, _reason, resources} =
               run_content(ctx.scope, publish: fn _scope -> {:error, %{message: "bucket gone"}} end)

      assert [failure] = find(resources, "content_failure")
      assert failure.identifier =~ "objects_uploaded=false"
      assert find(resources, "content_object") == []
    end
  end

  describe "no content yet, but publishing is wired" do
    # The ordinary state of a freshly generated project: nothing has been
    # authored, and the step should say so as `:ok` rather than error on a
    # project that has done nothing wrong yet.
    test "reports done with an honest note instead of erroring", ctx do
      assert {:ok, [resource]} =
               Steps.run(:content, ctx.scope,
                 publish: fn _scope -> flunk("nothing to publish — should not call publish") end
               )

      assert resource.kind == "content"
      assert resource.location == "no content to publish yet"
    end
  end

  describe "no content bucket — the real precondition unmet" do
    # `content_bucket` is written by the storage step once its bucket exists,
    # not typed in by hand. A project whose storage step is still paused on
    # Sam's console-only Hetzner key never gets one — reporting this step
    # `:done` with "no content to publish yet" would hide that storage is
    # what he is actually still waiting on, the same silently-vacuous shape
    # already fixed once for the `:email` step.
    test "pauses instead of reporting done when content_bucket was never set", ctx do
      {:ok, project} =
        CodeMySpec.Projects.update_project(ctx.scope, ctx.scope.active_project, %{
          content_bucket: nil
        })

      scope = %{ctx.scope | active_project: project}

      assert {:paused, message} =
               Steps.run(:content, scope,
                 publish: fn _scope -> flunk("not publishable — should not call publish") end
               )

      assert message =~ "content_bucket"
      assert message =~ "storage"
    end
  end
end
