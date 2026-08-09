defmodule CmsHarness.AnalyzerEnvTest do
  @moduledoc """
  The analyzer builds somewhere the agent does not.

  Sharing `_build` meant an agent's own `mix compile --force` wiped and rebuilt
  it underneath a running suite: modules vanished mid-run and returned as
  `(module CodeMySpec.Mail.ResendClient is not available)` for a module that
  exists and was never touched — 14 of 46 reported failures on one occasion,
  and indistinguishable from a real missing dependency.

  It is also how the single-flight guard got wedged: an analyzer waiting on the
  build lock holds it, and every stop inside that window is refused. Five
  consecutive stops on a finding already fixed and pushed.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.AnalyzerEnv
  alias CodeMySpec.Environments.Environment

  defp env_for(cwd), do: Environment.new(:local, cwd)

  test "the analyzer's build path is not the agent's" do
    {:ok, cwd} = Briefly.create(directory: true)

    assert {"MIX_BUILD_PATH", build} =
             cwd |> env_for() |> AnalyzerEnv.extra_env() |> List.keyfind("MIX_BUILD_PATH", 0)

    refute build == Path.join(cwd, "_build"),
           "sharing _build is what let an agent's compile pull modules out from " <>
             "under a running suite"
  end

  test "it lives under _build, so it inherits the gitignore" do
    {:ok, cwd} = Briefly.create(directory: true)

    assert AnalyzerEnv.build_path(cwd) == Path.join(cwd, "_build/analyzer"),
           "a sibling directory would need its own ignore entry, and would be " <>
             "committed by the first person who forgot"
  end

  test "every source gets the same build path" do
    {:ok, cwd} = Briefly.create(directory: true)
    env = AnalyzerEnv.extra_env(env_for(cwd))

    assert {"MIX_BUILD_PATH", path} = List.keyfind(env, "MIX_BUILD_PATH", 0)
    assert path == AnalyzerEnv.build_path(cwd)

    assert path == AnalyzerEnv.build_path(cwd),
           "isolating some sources would mean compiling into one tree and " <>
             "testing from another — slower than sharing and no safer"
  end

  test "two working copies do not share an analyzer build" do
    {:ok, a} = Briefly.create(directory: true)
    {:ok, b} = Briefly.create(directory: true)

    refute AnalyzerEnv.build_path(a) == AnalyzerEnv.build_path(b)
  end
end
