defmodule CodeMySpec.Generators.ForceSslExcludesHealthTest do
  @moduledoc """
  `force_ssl`, when configured, must exclude the health path — but only when
  it is actually configured, not merely mentioned.

  Found live adopting broken_oaths: `config/runtime.exs` carries `phx.new`'s
  own boilerplate, which ships `force_ssl` commented out and never enabled.
  The check's original implementation was a raw `String.contains?/2` against
  the whole file body, so the inert comment block refused the deploy exactly
  as if a real, unexcluded `force_ssl` were live — `config/runtime.exs`
  configures no `force_ssl` at all, and the string still counted.
  """

  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Environments.{Environment, Local}
  alias CodeMySpec.Generators.DeployBoilerplate

  setup do
    previous = Application.get_env(:code_my_spec, :environment)
    Application.put_env(:code_my_spec, :environment, Local)
    on_exit(fn -> Application.put_env(:code_my_spec, :environment, previous) end)

    {:ok, dir} = Briefly.create(directory: true)
    %{env: Environment.new(:local, dir), dir: dir}
  end

  defp write_runtime_exs(dir, contents) do
    File.write!(Path.join(dir, "runtime.exs"), contents)
  end

  test "no force_ssl anywhere is fine", %{env: env, dir: dir} do
    write_runtime_exs(dir, """
    import Config
    config :my_app, MyAppWeb.Endpoint, url: [host: "example.com"]
    """)

    assert :ok = DeployBoilerplate.force_ssl_excludes_health(env, "runtime.exs")
  end

  test "an active force_ssl that excludes the health path is fine", %{env: env, dir: dir} do
    write_runtime_exs(dir, """
    import Config

    config :my_app, MyAppWeb.Endpoint,
      force_ssl: [hsts: true, exclude: [paths: ["/up"]]]
    """)

    assert :ok = DeployBoilerplate.force_ssl_excludes_health(env, "runtime.exs")
  end

  test "an active force_ssl with no health exclusion is refused", %{env: env, dir: dir} do
    write_runtime_exs(dir, """
    import Config

    config :my_app, MyAppWeb.Endpoint,
      force_ssl: [hsts: true]
    """)

    assert {:error, {:force_ssl_without_health_exclusion, "runtime.exs"}} =
             DeployBoilerplate.force_ssl_excludes_health(env, "runtime.exs")
  end

  # The exact shape phx.new ships, commented out, never enabled.
  test "force_ssl commented out — phx.new's own boilerplate — is fine", %{env: env, dir: dir} do
    write_runtime_exs(dir, """
    import Config

    # ## Using releases
    # If you are doing OTP releases, you need to instruct Phoenix
    # to start each relevant endpoint:
    #
    #     config :my_app, MyAppWeb.Endpoint, server: true
    #
    # Then you can assemble a release by calling `mix release`.
    # See `mix help release` for more information.
    if config_env() == :prod do
      # config :my_app, MyAppWeb.Endpoint,
      #   force_ssl: [hsts: true]
    end
    """)

    assert :ok = DeployBoilerplate.force_ssl_excludes_health(env, "runtime.exs")
  end

  test "an active force_ssl still refuses even beside an unrelated comment mentioning it", %{
    env: env,
    dir: dir
  } do
    write_runtime_exs(dir, """
    import Config

    # We rely on force_ssl below; do not remove it.
    config :my_app, MyAppWeb.Endpoint,
      force_ssl: [hsts: true]
    """)

    assert {:error, {:force_ssl_without_health_exclusion, "runtime.exs"}} =
             DeployBoilerplate.force_ssl_excludes_health(env, "runtime.exs")
  end
end
