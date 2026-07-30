defmodule CodeMySpec.GeneratorsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Generators

  @router "lib/my_app_web/router.ex"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    %{env: Environment.new(:local, tmp), dir: tmp}
  end

  defp write(dir, path, contents) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp good_router do
    """
    defmodule MyAppWeb.Router do
      use MyAppWeb, :router

      pipeline :browser do
        plug :fetch_session
      end

      scope "/", MyAppWeb do
        get "/health", HealthController, :show
      end

      scope "/", MyAppWeb do
        pipe_through :browser
        get "/", PageController, :home
      end
    end
    """
  end

  defp good_runtime do
    """
    import Config

    if config_env() == :prod do
      config :my_app, MyAppWeb.Endpoint,
        force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["/health", "localhost"]]
    end
    """
  end

  defp deployable_project(dir) do
    for path <- [
          "Dockerfile",
          ".github/workflows/build.yml",
          "config/deploy.yml",
          "config/deploy.uat.yml",
          ".sops.yaml",
          "rel/overlays/bin/migrate",
          "bin/deploy",
          "envs/prod.enc.env",
          "envs/uat.enc.env"
        ] do
      write(dir, path, "# generated\n")
    end

    write(dir, @router, good_router())
    write(dir, "config/runtime.exs", good_runtime())
  end

  describe "audit/2 on a fully generated project" do
    test "reports nothing missing", %{env: env, dir: dir} do
      deployable_project(dir)

      assert Generators.audit_environment(env, @router) == []
      assert Generators.deploy_ready?(%CodeMySpec.Users.Scope{environment: env}, @router)
    end
  end

  describe "missing artifacts" do
    test "names each missing file with the reason it matters", %{env: env, dir: dir} do
      deployable_project(dir)
      File.rm!(Path.join(dir, "Dockerfile"))

      [{:missing_file, artifact}] = Generators.audit_environment(env, @router)

      assert artifact.key == :dockerfile

      explanation = Generators.explain({:missing_file, artifact})
      assert explanation =~ "Dockerfile"
      assert explanation =~ "first push"
    end

    test "a missing encrypted env file is reported", %{env: env, dir: dir} do
      deployable_project(dir)
      File.rm!(Path.join(dir, "envs/uat.enc.env"))

      assert [{:missing_env_file, "envs/uat.enc.env"}] = Generators.audit_environment(env, @router)
    end
  end

  describe "content checks that file existence would miss" do
    test "a health route inside a pipeline is caught", %{env: env, dir: dir} do
      deployable_project(dir)

      write(dir, @router, """
      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        scope "/", MyAppWeb do
          pipe_through :browser
          get "/health", HealthController, :show
        end
      end
      """)

      findings = Generators.audit_environment(env, @router)

      assert {:health_route_piped, @router} in findings

      assert Generators.explain({:health_route_piped, @router}) =~ "CSRF"
    end

    test "a router with no health route at all is caught", %{env: env, dir: dir} do
      deployable_project(dir)

      write(dir, @router, """
      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
      end
      """)

      assert {:no_health_route, @router} in Generators.audit_environment(env, @router)
    end

    test "force_ssl without a health exclusion is caught", %{env: env, dir: dir} do
      deployable_project(dir)

      write(dir, "config/runtime.exs", """
      import Config
      config :my_app, MyAppWeb.Endpoint,
        force_ssl: [rewrite_on: [:x_forwarded_proto]]
      """)

      findings = Generators.audit_environment(env, @router)

      assert {:force_ssl_without_health_exclusion, "config/runtime.exs"} in findings
    end

    test "no force_ssl at all is fine — nothing can redirect the probe", %{env: env, dir: dir} do
      deployable_project(dir)
      write(dir, "config/runtime.exs", "import Config\n")

      assert Generators.audit_environment(env, @router) == []
    end
  end

  describe "a project that is not safe to push" do
    test "a plaintext env file is reported", %{env: env, dir: dir} do
      deployable_project(dir)
      write(dir, ".env", "SECRET_KEY_BASE=oops\n")

      assert {:plaintext_env_file, ".env"} in Generators.audit_environment(env, @router)
    end
  end
end
