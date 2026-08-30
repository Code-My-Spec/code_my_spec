defmodule CodeMySpec.Provisioning.DeployReadinessAppNameTest do
  @moduledoc """
  Which app name the deploy-readiness check derives its file paths from.

  Reported live against MarketMySpec: `run(:deploy, ...)` named
  `lib/app_web/router.ex` and `lib/app/release.ex` as missing — Phoenix's own
  generator template path, before a project's real name is substituted in,
  and never actually right for any real project. The project's `module_name`
  had never arrived (a separate onboarding gap, in the sync payload — not
  reproduced here), and the fallback for that case was a literal `"App"`, so
  every check built on it looked at the wrong files.

  `mix.exs`'s own `app:` atom is never ambiguous, so it is read directly
  first; `module_name` remains a fallback for an environment `mix.exs` cannot
  be read from. Both are exercised here against the real, local environment
  `full_scope_fixture/1` anchors to a tmp dir — matching how
  `inbound_probe_default_test.exs` and its neighbours in this directory
  already test `Steps.run/3`, rather than reaching into its private
  functions directly.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Steps

  describe "mix.exs is readable" do
    test "the real app: atom wins, even over a stale module_name", %{} do
      scope = full_scope_fixture(%{module_name: "SomethingStale"})

      :ok =
        Environments.write_file(scope.environment, "mix.exs", """
        defmodule MarketMySpec.MixProject do
          use Mix.Project

          def project do
            [app: :market_my_spec, version: "0.1.0"]
          end
        end
        """)

      assert {:error, reason} = Steps.run(:deploy, scope, [])

      assert reason =~ "lib/market_my_spec_web/router.ex"
      assert reason =~ "lib/market_my_spec/release.ex"
      refute reason =~ "lib/app_web", "the unsubstituted generator template path leaked through"
    end
  end

  describe "mix.exs is not readable" do
    test "falls back to module_name rather than the literal \"App\"", %{} do
      scope = full_scope_fixture(%{module_name: "MarketMySpec"})

      assert {:error, reason} = Steps.run(:deploy, scope, [])

      assert reason =~ "lib/market_my_spec_web/router.ex"
      refute reason =~ "lib/app_web", "the unsubstituted generator template path leaked through"
    end
  end
end
