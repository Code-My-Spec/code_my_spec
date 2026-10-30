defmodule CodeMySpec.StaticAnalysis.CredoCompileBeforeJsonTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.StaticAnalysis.CredoRun

  @tag timeout: 120_000
  test "a checkout with an uncompiled dependency returns Credo's JSON alone" do
    root = CodeMySpec.TempFile.owned_dir("credo_compile_before_json")

    put(root, "mix.exs", """
    defmodule Sample.MixProject do
      use Mix.Project
      def project, do: [app: :sample, version: "0.1.0", deps: [{:credo, path: "deps/credo"}, {:chatter, path: "deps/chatter"}]]
    end
    """)

    put(root, "deps/chatter/mix.exs", """
    defmodule Chatter.MixProject do
      use Mix.Project
      def project, do: [app: :chatter, version: "0.1.0"]
    end
    """)

    put(root, "deps/chatter/lib/chatter.ex", """
    defmodule Chatter do
      def hello, do: :world
    end
    """)

    put(root, "deps/credo/mix.exs", """
    defmodule FixtureCredo.MixProject do
      use Mix.Project
      def project, do: [app: :credo, version: "0.1.0"]
    end
    """)

    put(root, "deps/credo/lib/mix/tasks/credo.ex", """
    defmodule Mix.Tasks.Credo do
      use Mix.Task
      @requirements ["loadpaths"]
      def run(_args), do: IO.puts(~s({"issues":[{"message":"found"}]}))
    end
    """)

    refute File.exists?(Path.join(root, "_build/dev/lib/chatter/ebin/Elixir.Chatter.beam"))
    env = ExecutionContext.new(:local, root)
    assert {:ok, [%{"message" => "found"}], raw} = CredoRun.run(env)
    assert Jason.decode!(raw) == %{"issues" => [%{"message" => "found"}]}
    assert File.exists?(Path.join(root, "_build/dev/lib/chatter/ebin/Elixir.Chatter.beam"))
  end

  defp put(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
