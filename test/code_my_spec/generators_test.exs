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
        force_ssl: [
          rewrite_on: [:x_forwarded_proto],
          exclude: [paths: ["/health"], hosts: ["localhost", "127.0.0.1"]]
        ]
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
          "rel/overlays/bin/boot",
          "rel/overlays/bin/migrate",
          "bin/deploy",
          "bin/backup",
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

    # The form that reads as an exclusion and is not one. Plug.SSL's `:exclude`
    # must be `[hosts: ...]`, `[paths: ...]` or `[conn: ...]`; a bare list of
    # strings matches none of those and excludes nothing. This check used to
    # accept it, so a generated project passed the audit, deployed, and the
    # proxy's plain-HTTP probe of /health still got a 301 — which fails as
    # "target failed to become healthy within configured timeout (30s)" and
    # names neither the config nor the redirect.
    test "a flat exclude list is not a health exclusion", %{env: env, dir: dir} do
      deployable_project(dir)

      write(dir, "config/runtime.exs", """
      import Config
      config :my_app, MyAppWeb.Endpoint,
        force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["/health", "localhost"]]
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

  describe "generated deploy configuration" do
    alias CodeMySpec.Generators.DeployArtifacts

    setup %{env: env, dir: dir} do
      {:ok, _written} =
        DeployArtifacts.generate(env, app: "my-app", host: "example.com", owner: "acme")

      %{dir: dir}
    end

    # The whole tree, not just the file under suspicion: an unrendered tag is a
    # class of bug, and it hid in the one line nobody reads because everything
    # around it interpolated correctly.
    test "no generated file carries an unrendered template tag", %{dir: dir} do
      offenders =
        Path.wildcard(Path.join(dir, "**/*"))
        |> Enum.filter(fn path ->
          File.regular?(path) and path |> File.read!() |> String.contains?("<%=")
        end)
        |> Enum.map(&Path.relative_to(&1, dir))

      assert offenders == [],
             """
             These generated files still contain EEx tags:

             #{Enum.map_join(offenders, "\n", &("  " <> &1))}

             Nothing renders these files — they are written as-is and handed to
             kamal. A tag that survives generation names a host that cannot exist.
             """
    end

    test "each environment's deploy config names its own host as the server", %{dir: dir} do
      prod = File.read!(Path.join(dir, "config/deploy.yml"))
      uat = File.read!(Path.join(dir, "config/deploy.uat.yml"))

      assert prod =~ ~r/servers:\s*\n\s*web:\s*\n\s*- example\.com/
      assert uat =~ ~r/servers:\s*\n\s*web:\s*\n\s*- uat\.example\.com/

      # And the two are genuinely different deploys, not one file twice.
      assert prod =~ "service: my-app\n"
      assert uat =~ "service: my-app-uat\n"
    end
  end

end
