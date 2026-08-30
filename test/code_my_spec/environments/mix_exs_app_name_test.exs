defmodule CodeMySpec.Environments.MixExsAppNameTest do
  @moduledoc """
  What `mix_exs_app_name/1` answers for a real checkout, and what it refuses
  to guess at.

  The one place this is never ambiguous: `mix.exs`'s own `app:` atom is what
  `mix release` and `mix phx.gen` themselves resolve every `lib/<app>(_web)/`
  path from. See `CodeMySpec.Provisioning.Steps.app_path/1` for why this
  exists — it stopped a deploy-readiness check from guessing the literal
  `"App"` for a project whose `module_name` had never been set.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  setup do
    {:ok, dir} = Briefly.create(directory: true)
    %{env: Environment.new(:local, dir)}
  end

  test "reads the app: atom off a normal, single-line mix.exs", %{env: env} do
    Environments.write_file(env, "mix.exs", """
    defmodule MarketMySpec.MixProject do
      use Mix.Project
      def project, do: [app: :market_my_spec, version: "0.1.0"]
    end
    """)

    assert Environments.mix_exs_app_name(env) == "market_my_spec"
  end

  test "reads it off the multi-line list shape mix new actually generates", %{env: env} do
    Environments.write_file(env, "mix.exs", """
    defmodule MarketMySpec.MixProject do
      use Mix.Project

      def project do
        [
          app: :market_my_spec,
          version: "0.1.0",
          elixir: "~> 1.18"
        ]
      end
    end
    """)

    assert Environments.mix_exs_app_name(env) == "market_my_spec"
  end

  test "nil when there is no mix.exs at all", %{env: env} do
    assert Environments.mix_exs_app_name(env) == nil
  end

  test "nil for an environment that cannot be read from" do
    assert Environments.mix_exs_app_name(nil) == nil
  end

  test "nil when mix.exs exists but names no app", %{env: env} do
    Environments.write_file(env, "mix.exs", """
    defmodule Broken.MixProject do
      use Mix.Project
      def project, do: [version: "0.1.0"]
    end
    """)

    assert Environments.mix_exs_app_name(env) == nil
  end
end
