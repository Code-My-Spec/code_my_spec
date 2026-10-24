defmodule CodeMySpec.Promotion.AGateBuildsTheProjectsAssetsTest do
  @moduledoc """
  Issue 47567b2a: none of compiler, credo, exunit or spex run the project's
  asset pipeline, so story 1092's broken `echarts` import failed esbuild
  from the moment its batch landed -- every analyzer green, the dev app
  running every LiveView page with no JavaScript at all.

  `Steps.build_assets/2` is the gate's own check: `mix assets.build` in the
  checkout being judged, skipped for a fixture with no real project to
  build (a bare git repo with no `mix.exs`, the shape every
  `promotion_queue_test.exs` fixture already is).
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Support.InMemoryExecutionContext

  defp script(answers) do
    fn command, args, _opts -> Map.fetch!(answers, {command, args}) end
  end

  test "a checkout with no mix.exs is skipped, not failed" do
    {:ok, env} = InMemoryExecutionContext.create(shell: script(%{}))

    assert {:ok, %{skipped: true}} = Steps.build_assets(env, env.cwd)
  end

  test "a broken bundle refuses, naming the build's own output" do
    answers = %{
      {"mix", ["assets.build"]} =>
        {"../deps/echarts/src/echart.js:1\nCould not resolve \"echarts\"", 1}
    }

    {:ok, env} = InMemoryExecutionContext.create(shell: script(answers))

    :ok =
      InMemoryExecutionContext.write_file(env, "mix.exs", "defmodule App.MixProject do\nend\n")

    assert {:error, %{reason: reason}} = Steps.build_assets(env, env.cwd)
    assert reason =~ "failed to build"
    assert reason =~ "Could not resolve \"echarts\""
  end

  test "a clean bundle passes" do
    answers = %{{"mix", ["assets.build"]} => {"", 0}}

    {:ok, env} = InMemoryExecutionContext.create(shell: script(answers))

    :ok =
      InMemoryExecutionContext.write_file(env, "mix.exs", "defmodule App.MixProject do\nend\n")

    assert {:ok, %{}} = Steps.build_assets(env, env.cwd)
  end
end
