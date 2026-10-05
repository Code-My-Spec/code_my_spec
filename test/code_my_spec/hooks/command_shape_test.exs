defmodule CodeMySpec.Hooks.CommandShapeTest do
  @moduledoc """
  The shapes are agents' own, mined from transcripts (2026-10-05), with paths
  shortened.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Hooks.CommandShape

  defp run(%{source: source, args: args}), do: {:ok, "RUN(#{source} #{Enum.join(args, " ")})"}

  defp route(command), do: CommandShape.route(command, &run/1)

  describe "routes only the test segment" do
    test "a bare run" do
      assert {:routed, "RUN(exunit test/a_test.exs)", [:simple], [%{task: "test"}]} =
               route("mix test test/a_test.exs")
    end

    test "the commonest shape: env, redirect, pipe" do
      assert {:routed, "RUN(exunit test/a_test.exs:12) 2>&1 | tail -20", classes, _} =
               route("MIX_ENV=test mix test test/a_test.exs:12 2>&1 | tail -20")

      assert :piped in classes and :redirected in classes
    end

    test "a pipe into grep with quotes and regex characters" do
      command =
        ~S{MIX_ENV=test mix test test/a_test.exs 2>&1 | grep -E "^\s+[0-9]\) test|tests, " | head -14}

      assert {:routed, routed, _, _} = route(command)

      assert routed ==
               ~S{RUN(exunit test/a_test.exs) 2>&1 | grep -E "^\s+[0-9]\) test|tests, " | head -14}
    end

    test "cd before it is kept, and carried on the run" do
      assert {:routed, "cd /w/copy && RUN(exunit test/a_test.exs) 2>&1 | tail -30", classes,
              [%{cd: "/w/copy"}]} =
               route("cd /w/copy && MIX_ENV=test mix test test/a_test.exs 2>&1 | tail -30")

      assert :cd in classes
    end

    test "commands after it are kept" do
      assert {:routed, ~S{RUN(exunit test/a_test.exs) 2>&1 | tail -4; echo "done"}, _, _} =
               route(~S{MIX_ENV=test mix test test/a_test.exs 2>&1 | tail -4; echo "done"})
    end

    test "commands before it are kept" do
      assert {:routed,
              "lsof -ti:4002 | xargs -r kill -9 2>/dev/null; sleep 2; RUN(exunit test/a_test.exs) 2>&1 | tail -6",
              _,
              _} =
               route(
                 "lsof -ti:4002 | xargs -r kill -9 2>/dev/null; sleep 2; MIX_ENV=test mix test test/a_test.exs 2>&1 | tail -6"
               )
    end

    test "a redirect to a file keeps its target" do
      assert {:routed, "RUN(spex test/spex/x_spex.exs) > out.txt 2>&1", _, _} =
               route("mix spex test/spex/x_spex.exs > out.txt 2>&1")
    end

    test "flags and quoted args are parsed as mix would" do
      assert {:routed, _, _, [%{args: ["--only", "slow", "test/a b_test.exs"]}]} =
               route(~S{mix test --only slow "test/a b_test.exs"})
    end

    test "an && inside quotes is not an operator" do
      assert {:routed, ~S{echo "a && b" && RUN(exunit )}, _, _} =
               route(~S{echo "a && b" && mix test})
    end
  end

  describe "passes through" do
    test "a command with no test in it" do
      assert {:pass, [:not_test]} = route("git status && mix compile")
    end

    test "an env prefix the run would drop" do
      assert {:pass, [:env]} = route("MIX_ENV=cli_dev mix test test/a_test.exs")
    end

    test "a heredoc, even with the test elsewhere" do
      assert {:pass, [:unparseable]} =
               route("python3 - <<'PY'\nprint(1)\nPY\nmix test test/a_test.exs")
    end

    test "a command substitution" do
      assert {:pass, [:unparseable]} = route(~S{mix test $(git diff --name-only)})
    end

    test "backgrounding" do
      assert {:pass, [:unparseable]} = route("mix test test/a_test.exs &")
    end

    test "unbalanced quotes" do
      assert {:pass, [:unparseable]} = route(~S{mix test "test/a_test.exs})
    end

    test "a segment the caller declines" do
      assert {:pass, [:simple]} = CommandShape.route("mix test", fn _ -> :pass end)
    end
  end
end
