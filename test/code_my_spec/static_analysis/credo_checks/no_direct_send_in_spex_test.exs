Code.compile_file("priv/credo_checks/no_direct_send_in_spex.ex")

defmodule CodeMySpec.Check.Warning.NoDirectSendInSpexTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Check.Warning.NoDirectSendInSpex

  defp run_check(source_code, filename) do
    source_code
    |> Credo.SourceFile.parse(filename)
    |> NoDirectSendInSpex.run([])
  end

  describe "run/2" do
    test "flags send/2 in _spex.exs files" do
      source = """
      defmodule MySpex do
        use SexySpex

        spex "something" do
          scenario "test" do
            when_ "message sent", context do
              send(context.view.pid, {:sync_completed, %{}})
              {:ok, context}
            end
          end
        end
      end
      """

      issues = run_check(source, "test/spex/my_feature_spex.exs")
      assert length(issues) == 1

      issue = hd(issues)
      assert issue.check == NoDirectSendInSpex
      assert issue.trigger == "send"
      assert issue.message =~ "Direct `send()`"
    end

    test "flags multiple send/2 calls" do
      source = """
      defmodule MySpex do
        spex "something" do
          scenario "test" do
            when_ "first", ctx do
              send(ctx.pid, :msg1)
              {:ok, ctx}
            end

            when_ "second", ctx do
              send(ctx.pid, :msg2)
              {:ok, ctx}
            end
          end
        end
      end
      """

      issues = run_check(source, "test/spex/multi_send_spex.exs")
      assert length(issues) == 2
    end

    test "flags Kernel.send/2 in _spex.exs files" do
      source = """
      defmodule MySpex do
        spex "something" do
          scenario "test" do
            when_ "message sent", context do
              Kernel.send(context.view.pid, {:event, %{}})
              {:ok, context}
            end
          end
        end
      end
      """

      issues = run_check(source, "test/spex/kernel_send_spex.exs")
      assert length(issues) == 1
      assert hd(issues).trigger == "Kernel.send"
    end

    test "ignores send/2 in non-spex files" do
      source = """
      defmodule MyTest do
        test "sends a message" do
          send(self(), :hello)
        end
      end
      """

      assert run_check(source, "test/my_test.exs") == []
      assert run_check(source, "lib/my_module.ex") == []
      assert run_check(source, "test/spex/helper.exs") == []
    end

    test "ignores files without send calls" do
      source = """
      defmodule CleanSpex do
        use SexySpex

        spex "something" do
          scenario "clean test" do
            given_ "setup", context do
              {:ok, context}
            end

            then_ "assertion", context do
              assert true
              :ok
            end
          end
        end
      end
      """

      assert run_check(source, "test/spex/clean_spex.exs") == []
    end

    test "reports correct line numbers" do
      source = """
      defmodule MySpex do
        spex "x" do
          scenario "y" do
            when_ "z", ctx do
              send(ctx.pid, :msg)
              {:ok, ctx}
            end
          end
        end
      end
      """

      [issue] = run_check(source, "test/spex/line_no_spex.exs")
      assert issue.line_no == 5
    end
  end
end
