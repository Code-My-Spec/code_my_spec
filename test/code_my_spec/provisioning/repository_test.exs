defmodule CodeMySpec.Provisioning.RepositoryTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.GitHub
  alias CodeMySpec.Provisioning.Repository

  doctest Repository, only: [default_name: 1]

  @project %{name: "Sams Thing"}
  @repo %{"name" => "sams-thing", "clone_url" => "https://github.com/sam/sams-thing.git"}

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    # A connected GitHub App installation. The auth path is real — only HTTP
    # is stubbed — so a change to how the token is resolved surfaces here.
    _ = github_integration_fixture(scope.user)

    %{env: Environment.new(:local, tmp), scope: scope}
  end

  defp stub_github(fun) do
    Application.put_env(:code_my_spec, GitHub, plug: fun)
    on_exit(fn -> Application.delete_env(:code_my_spec, GitHub) end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp pushes(sha), do: fn _env, _url, _opts -> {:ok, sha} end
  defp rejects(reason), do: fn _env, _url, _opts -> {:error, reason} end

  describe "default_name/1" do
    test "slugifies the project name" do
      assert Repository.default_name(%{name: "Code My Spec"}) == "code-my-spec"
      assert Repository.default_name(%{name: "Sam's Thing!"}) == "sam-s-thing"
    end

    # It is a default, not a rule — the PM answered that naming is overridable.
    test "an explicit name wins over the default", ctx do
      stub_github(fn
        %{method: "GET"} = conn ->
          json(conn, 404, %{})

        %{method: "POST"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert Jason.decode!(body)["name"] == "something-else",
                 "expected the override to be used, not the slugified project name"

          json(conn, 201, @repo)
      end)

      assert {:ok, :created, _} =
               Repository.ensure(ctx.scope, @project, name: "something-else", owner: "sam")
    end
  end

  describe "adoption versus collision" do
    # These are the same situation — a repository already exists — and
    # conflating them produces one of two bugs. Adoption is Sam having chosen
    # it; collision is setup finding something he never pointed at.
    test "adopt: true takes the existing repository and creates nothing", ctx do
      stub_github(fn
        %{method: "GET"} = conn ->
          json(conn, 200, @repo)

        %{method: "POST"} = conn ->
          flunk("created a repository when adopting an existing one")
          conn
      end)

      assert {:ok, :adopted, %{"name" => "sams-thing"}} =
               Repository.ensure(ctx.scope, @project, owner: "sam", adopt: true)
    end

    # Criterion 8185: neither choice is taken on Sam's behalf.
    test "without an explicit choice the collision is reported with both options", ctx do
      stub_github(fn
        %{method: "GET"} = conn ->
          json(conn, 200, @repo)

        %{method: "POST"} = conn ->
          flunk("created a repository despite a name collision")
          conn
      end)

      assert {:name_taken, collision} = Repository.ensure(ctx.scope, @project, owner: "sam")

      assert collision.choices == [:adopt, :rename]
      assert collision.message =~ "sams-thing"
      assert collision.message =~ ~r/adopt/i
      assert collision.message =~ ~r/another name/i
    end

    test "a free name is simply created", ctx do
      stub_github(fn
        %{method: "GET"} = conn -> json(conn, 404, %{})
        %{method: "POST"} = conn -> json(conn, 201, @repo)
      end)

      assert {:ok, :created, _} = Repository.ensure(ctx.scope, @project, owner: "sam")
    end
  end

  describe "what gets created" do
    test "is private by default", ctx do
      stub_github(fn
        %{method: "GET"} = conn ->
          json(conn, 404, %{})

        %{method: "POST"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["private"] == true
          json(conn, 201, @repo)
      end)

      assert {:ok, :created, _} = Repository.ensure(ctx.scope, @project, owner: "sam")
    end

    test "an organisation repository goes to the org endpoint, not /user/repos", ctx do
      stub_github(fn
        %{method: "GET"} = conn ->
          json(conn, 404, %{})

        %{method: "POST", request_path: path} = conn ->
          assert path == "/orgs/sams-org/repos",
                 "expected the org endpoint, got #{path}"

          json(conn, 201, @repo)
      end)

      assert {:ok, :created, _} =
               Repository.ensure(ctx.scope, @project, owner: "sams-org", org: "sams-org")
    end
  end

  describe "run/4 — done is a push, not a repository" do
    test "records the commit that landed and only then reports pushed", %{env: env} = ctx do
      stub_github(fn
        %{method: "GET"} = conn -> json(conn, 404, %{})
        %{method: "POST"} = conn -> json(conn, 201, @repo)
      end)

      result = Repository.run(ctx.scope, env, @project, owner: "sam", push: pushes("abc123"))

      assert result.state == :pushed
      assert result.commit == "abc123"
      assert %DateTime{} = result.pushed_at
      assert result.disposition == :created
    end

    # Criterion 8184. Reporting "repository created" here would be true and
    # useless — the harness would fail on its first push, far from setup.
    test "a repository that exists but rejects the push is not done", %{env: env} = ctx do
      stub_github(fn
        %{method: "GET"} = conn -> json(conn, 404, %{})
        %{method: "POST"} = conn -> json(conn, 201, @repo)
      end)

      result =
        Repository.run(ctx.scope, env, @project,
          owner: "sam",
          push: rejects("remote: Write access to repository not granted")
        )

      assert result.state == :push_rejected
      assert result.pushed_at == nil
      assert result.commit == nil
      # The repository IS recorded — it exists — but that is not completion.
      assert result.repository != nil
      assert result.reason =~ ~r/push was rejected/i
      assert result.reason =~ "Write access"
    end
  end

  describe "run/4 — no credential fallback" do
    # Criterion 8181. A fallback would create the repository under the wrong
    # account and look like success.
    test "a revoked connection stops and names reconnecting", %{env: env} do
      # A scope whose user has revoked the installation — no integration row.
      revoked = full_scope_fixture()

      result =
        Repository.run(revoked, env, @project,
          owner: "sam",
          push: fn _, _, _ -> flunk("pushed despite having no GitHub connection") end
        )

      assert result.state == :not_connected
      assert result.reason =~ ~r/reconnect/i
      assert result.repository == nil
      assert result.pushed_at == nil
    end
  end

  describe "run/4 — a collision surfaces both choices" do
    test "reports name_taken and pushes nothing", %{env: env} = ctx do
      stub_github(fn conn -> json(conn, 200, @repo) end)

      result =
        Repository.run(ctx.scope, env, @project,
          owner: "sam",
          push: fn _, _, _ -> flunk("pushed into a repository Sam had not chosen") end
        )

      assert result.state == :name_taken
      assert result.choices == [:adopt, :rename]
      assert result.pushed_at == nil
    end
  end
end
