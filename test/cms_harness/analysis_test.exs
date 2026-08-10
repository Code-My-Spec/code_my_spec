defmodule CmsHarness.AnalysisTest do
  @moduledoc """
  The analyzers, run for real against real working copies on disk.

  No stubs and no recorded output: these shell out to `mix`, because being the
  half that can is the whole reason this module exists. A test that faked the
  command would assert that the harness formats a payload, which was never in
  doubt — what was in doubt is whether it runs anything at all, and for two
  phases it did not.

  The fixture project takes `client_utils` as a path dependency, because the
  `:diagnostics` compiler is what writes the JSONL `CodeMySpec.Compile` reads,
  and a project without it is a different (and much worse) case — see the test
  that records it. Point `CMS_CLIENT_UTILS` at a checkout; it defaults to the
  sibling `../client_utils`.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Analysis

  # Nothing here fetches from the network beyond `client_utils`'s two small hex
  # deps, but a cold `_build` on a loaded machine outruns ExUnit's default.
  @moduletag timeout: 300_000

  @client_utils System.get_env("CMS_CLIENT_UTILS") ||
                  Path.expand("../client_utils", File.cwd!())

  setup_all do
    {:ok, client_utils?: File.exists?(Path.join(@client_utils, "mix.exs"))}
  end

  defp mix_project(files, opts \\ []) do
    root =
      Path.join(System.tmp_dir!(), "cms_harness_analysis_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), mix_exs(opts))

    Enum.each(files, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    fetch_deps(root, Keyword.get(opts, :client_utils, false))

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, id: "analysis-test"}
  end

  # Only the `client_utils` variant has a dependency to fetch. The `{_, 0}`
  # match is the assertion: a fixture whose deps did not resolve would fail
  # later as a compile error and read as the thing under test.
  defp fetch_deps(root, true) do
    {_, 0} = System.cmd("mix", ["deps.get"], cd: root, stderr_to_stdout: true)
    :ok
  end

  defp fetch_deps(_root, false), do: :ok

  defp mix_exs(opts), do: mix_exs_for(Keyword.get(opts, :client_utils, false))

  # The two fixture shapes the module is about: one whose `compilers` list has
  # `:diagnostics` and one without. The difference is the whole point — see the
  # test recording what happens to a broken project in the second.
  defp mix_exs_for(true) do
    """
    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo,
          version: "0.1.0",
          elixir: "~> 1.14",
          compilers: [:diagnostics] ++ Mix.compilers(),
          deps: [{:client_utils, path: #{inspect(@client_utils)}}]
        ]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp mix_exs_for(false) do
    """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: [app: :demo, version: "0.1.0", elixir: "~> 1.14"]
      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  # These analyzers shell out to `mix` against a fixture that takes
  # `client_utils` as a path dependency, so without a checkout there is nothing
  # to run. Two clauses rather than a guard inside each test: the skip is a
  # property of the environment, not a branch in the assertion.
  #
  # A warning rather than a silent pass, because "no checkout" and "the
  # analyzer works" must not look the same in the output.
  defp with_client_utils(%{client_utils?: true}, _what, fun), do: fun.()

  defp with_client_utils(%{client_utils?: false}, what, _fun) do
    IO.warn("no client_utils checkout at #{@client_utils}; #{what} not checked")
  end

  describe "compiler" do
    test "a file that cannot compile comes back as an error diagnostic", ctx do
      with_client_utils(ctx, "compile diagnostics", fn ->
        project =
          mix_project(
            %{
              "lib/broken.ex" => """
              defmodule Demo.Broken do
                def go do
                  unclosed(
                end
              end
              """
            },
            client_utils: true
          )

        assert {:ok, result} = Analysis.run(project, "compiler")

        assert result["source"] == "compiler"

        assert [_ | _] = result["diagnostics"],
               "a project that does not compile must not report an empty diagnostic " <>
                 "list — that is indistinguishable from a clean compile"

        assert Enum.any?(result["diagnostics"], &(&1["severity"] == "error")),
               "the server decides whether to block from severity, so a compile " <>
                 "error reported as anything else would not block"

        assert Enum.any?(result["diagnostics"], &(&1["file"] =~ "broken.ex")),
               "the diagnostic has to name the file, or the Problem lands on `unknown`"
      end)
    end

    test "a project that compiles reports no diagnostics", ctx do
      with_client_utils(ctx, "clean compile", fn ->
        project =
          mix_project(
            %{"lib/fine.ex" => "defmodule Demo.Fine do\n  def go, do: :ok\nend\n"},
            client_utils: true
          )

        assert {:ok, result} = Analysis.run(project, "compiler")
        assert result["diagnostics"] == []
      end)
    end

    # Recorded because it is a trap, not because it is right.
    #
    # `Compile.execute/1` runs `mix compile --return-errors`, and that flag makes
    # mix exit **0 even when compilation failed** — the errors are returned
    # rather than raised. `Compile` still reads the exit code as the signal, so
    # when the `:diagnostics` JSONL is absent it takes the "compilation
    # succeeded — treating as clean" branch and reports a broken project clean.
    # The raw output does contain the error (`== Compilation error in file …`)
    # and `Compile.extract_compiler_errors/1` would find it, but that fallback
    # only runs when the exit code is nonzero, which it now never is.
    #
    # This is the local server's behaviour too, not something the harness
    # introduced — the harness relays whatever `Compile` returned. It is only
    # reachable in a project whose `compilers` list omits `:diagnostics`, which
    # `Compile`'s own moduledoc names as a requirement. Left alone here
    # deliberately: changing what an analyzer means is not this change's job.
    test "a broken project WITHOUT the :diagnostics compiler is reported clean — a defect" do
      project =
        mix_project(%{
          "lib/broken.ex" => "defmodule Demo.Broken do\n  def go do\n    unclosed(\n  end\nend\n"
        })

      assert {:ok, result} = Analysis.run(project, "compiler")

      assert result["exit_status"] == 0,
             "`--return-errors` means the exit code is no longer a signal at all"

      assert result["diagnostics"] == [],
             """
             Diagnostics came back for a project with no :diagnostics compiler.

             That is what a fix looks like — `CodeMySpec.Compile` reading the raw
             output regardless of exit code — and if that is what happened, delete
             this test.

             Check first. This has also failed intermittently for reasons nobody
             has traced (issue 75b35ac2): full-suite runs only, never standalone,
             on a temp project that should have no way to produce diagnostics at
             all. An environmental failure presents exactly like a fix, and acting
             on the instruction above would delete a test guarding a trap that is
             still there.

             So: confirm `extract_compiler_errors/1` is actually reached on a zero
             exit before deleting anything. A self-deleting test that can fire by
             accident deletes itself by accident.
             """
    end
  end

  describe "exunit" do
    test "a failing test comes back as a failure diagnostic", ctx do
      with_client_utils(ctx, "exunit failures", fn ->
        project = exunit_project(ctx, "assert 1 == 2")

        assert {:ok, result} = Analysis.run(project, "exunit")

        assert result["execution_status"] == "failure"
        assert result["exit_status"] != 0

        assert [failure] = result["diagnostics"]
        assert failure["file"] =~ "demo_test.exs"
        assert failure["message"] =~ "1 == 2"

        assert result["stats"]["failures"] == 1,
               "stats ride into the run ledger, which is what the UI gauge reads"
      end)
    end

    # The distinction the whole design turns on, at the one place it has already
    # been got wrong: an empty failure list from a suite that never started
    # would clear every real exunit Problem and finish the run `:completed` at
    # the current fingerprint — which is precisely how `tests_passing` once went
    # green on a project whose tests all failed. `execution_status` is the field
    # the server refuses on, so the harness has to carry it.
    test "a suite that never started says so, rather than reporting no failures", ctx do
      with_client_utils(ctx, "the did-not-run case", fn ->
        project = exunit_project(ctx, "assert true")

        assert {:ok, result} = Analysis.run(project, "exunit", ["test/does_not_exist_test.exs"])

        assert result["execution_status"] == "error"
        assert result["diagnostics"] == []

        assert result["output"] =~ "did not match",
               "the server puts the tail of this into the run's error, so it has to say why"
      end)
    end

    defp exunit_project(_ctx, body) do
      mix_project(
        %{
          "lib/fine.ex" => "defmodule Demo.Fine do\n  def go, do: :ok\nend\n",
          "test/test_helper.exs" => "ExUnit.start()\n",
          "test/demo_test.exs" => """
          defmodule DemoTest do
            use ExUnit.Case
            test "it holds" do
              #{body}
            end
          end
          """
        },
        client_utils: true
      )
    end
  end

  # Found by running it: a project without `:credo` in its deps printed
  # `** (Mix) The task "credo" could not be found`, which is not JSON — and the
  # first version of the vendored runner mirrored the server's "unparseable
  # output means no issues", so the harness reported the project credo-clean and
  # the server recorded a completed run with zero problems. The server itself
  # never reaches that: `available?/1` skips the analyzer first.
  describe "credo" do
    test "a project without credo installed is an error, not a clean sweep" do
      project = mix_project(%{"lib/fine.ex" => "defmodule Demo.Fine do\nend\n"})

      assert {:error, reason} = Analysis.run(project, "credo")
      assert reason =~ "credo is not installed"
    end
  end

  test "an analyzer this harness does not know is an error, not an empty result" do
    project = mix_project(%{})

    assert {:error, reason} = Analysis.run(project, "dialyzer")
    assert reason =~ "unknown analyzer source"
  end
end
