defmodule CodeMySpec.Promotion.PromotionFormatsTheGateCheckoutTest do
  @moduledoc """
  Issue 0dc0f327: promotion runs `mix format` on the candidate and commits the
  result as its own commit before gating, so main cannot drift from
  `.formatter.exs` and no agent has to remember to format. The step reports the
  files and the commit, so the agent is told what changed; a tree that is
  already formatted makes no commit.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Support.InMemoryEnvironment

  @formatted_head "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"

  defp project(shell) do
    {:ok, env} = InMemoryEnvironment.create(shell: shell)
    :ok = InMemoryEnvironment.write_file(env, "mix.exs", "defmodule App.MixProject do\nend\n")
    :ok = InMemoryEnvironment.write_file(env, ".formatter.exs", "[inputs: [\"lib/**/*.ex\"]]\n")
    env
  end

  defp shell(changed) do
    fn
      "mix", ["format"], _opts -> {"", 0}
      "git", ["diff", "--name-only", "--ignore-submodules=all"], _opts -> {changed, 0}
      "git", ["config", "user.email"], _opts -> {"agent@example.com", 0}
      "git", ["add", "--" | _files], _opts -> {"", 0}
      "git", ["commit", "--quiet", "-m", _message], _opts -> {"", 0}
      "git", ["rev-parse", "HEAD"], _opts -> {@formatted_head <> "\n", 0}
    end
  end

  test "files the format changed are committed, and the result names them and the commit" do
    env = project(shell("lib/a.ex\nlib/b.ex\n"))

    assert {:ok, %{formatted: ["lib/a.ex", "lib/b.ex"], commit: @formatted_head} = result} =
             Steps.format(env, env.cwd)

    assert result.head == @formatted_head
  end

  test "an already formatted tree makes no commit" do
    env = project(shell(""))

    assert {:ok, %{formatted: [], commit: nil}} = Steps.format(env, env.cwd)
  end

  test "a format that fails refuses, naming mix's own output" do
    env =
      project(fn "mix", ["format"], _opts ->
        {"** (SyntaxError) lib/a.ex:3: unexpected token", 1}
      end)

    assert {:error, %{reason: reason}} = Steps.format(env, env.cwd)
    assert reason =~ "mix format failed"
    assert reason =~ "SyntaxError"
  end

  test "a checkout with no formatter config is skipped, not failed" do
    {:ok, env} = InMemoryEnvironment.create(shell: fn _, _, _ -> {"", 0} end)
    :ok = InMemoryEnvironment.write_file(env, "mix.exs", "defmodule App.MixProject do\nend\n")

    assert {:ok, %{skipped: true, commit: nil}} = Steps.format(env, env.cwd)
  end

  test "check names the unformatted files and changes nothing" do
    env =
      project(fn "mix", ["format", "--check-formatted"], _opts ->
        {"** (Mix) mix format failed due to --check-formatted.\nThe following files are not formatted:\n\n  * lib/a.ex\n  * lib/b.ex\n",
         1}
      end)

    assert {:ok, %{unformatted: ["lib/a.ex", "lib/b.ex"]}} =
             Steps.format(env, env.cwd, check: true)
  end

  test "check on a formatted tree finds nothing" do
    env = project(fn "mix", ["format", "--check-formatted"], _opts -> {"", 0} end)

    assert {:ok, %{unformatted: []}} = Steps.format(env, env.cwd, check: true)
  end
end
