defmodule CodeMySpec.Promotion.TestImpactBaselineTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.TestImpact

  @tag :tmp_dir
  test "compiled source and unexecuted tests yield a partial next selection", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule ImpactFixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :impact_fixture, version: \"0.1.0\", elixirc_paths: [\"lib\"]]\nend\n"
    )

    File.write!(
      Path.join(root, "lib/subject.ex"),
      "defmodule ImpactFixture.Subject do\n  def value, do: :ok\nend\n"
    )

    File.write!(
      Path.join(root, "lib/other.ex"),
      "defmodule ImpactFixture.Other do\n  def value, do: :other\nend\n"
    )

    File.write!(
      Path.join(root, "test/subject_test.exs"),
      "defmodule ImpactFixture.SubjectTest do\n  use ExUnit.Case\n  alias ImpactFixture.Subject\n  test \"works\" do\n    File.write!(\"test-executed\", \"ran\")\n    assert(Subject.value() == :ok)\n  end\nend\n"
    )

    File.write!(
      Path.join(root, "test/other_test.exs"),
      "defmodule ImpactFixture.OtherTest do\n  use ExUnit.Case\n  alias ImpactFixture.Other\n  test \"works\", do: assert(Other.value() == :other)\nend\n"
    )

    git!(root, ["init", "-q"])
    git!(root, ["add", "mix.exs", "lib", "test"])

    git!(root, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-qm",
      "baseline"
    ])

    base = git!(root, ["rev-parse", "HEAD"])

    {_, 0} =
      System.cmd("mix", ["compile"],
        cd: root,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}]
      )

    assert {:ok, %{manifest: dir}} =
             Steps.save_test_baseline(ExecutionContext.new(:local, root), root)

    assert File.exists?(Path.join(dir, "compile.test_impact"))
    refute File.exists?(Path.join(root, "test-executed"))
    assert {:ok, baseline} = TestImpact.read_baseline(dir)
    assert map_size(baseline.test_sources) == 2

    File.write!(
      Path.join(root, "lib/subject.ex"),
      "defmodule ImpactFixture.Subject do\n  def value, do: :changed\nend\n"
    )

    git!(root, ["add", "lib/subject.ex"])

    git!(root, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-qm",
      "change"
    ])

    head = git!(root, ["rev-parse", "HEAD"])

    assert {:ok, selection} =
             Steps.select_tests(ExecutionContext.new(:local, root), root, base, head)

    assert selection["mode"] == "partial"
    assert selection["selected_tests"] == ["test/subject_test.exs"]
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
