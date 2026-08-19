defmodule CodeMySpec.Qa.EvidenceTest do
  @moduledoc """
  A QA pass is an audit-grade claim, and this is what checks the evidence is
  still there tomorrow.

  `0a1435c7`: four briefs sat uncommitted in one worktree while the passes they
  backed had propagated to the server and closed `qa_complete`. One was for a
  story that shipped that night. The evidence existed on exactly one machine,
  and nothing said so at any point.

  The property that matters most here is the third answer. Two states are easy
  — committed, or not — and it is the "could not tell" case that turns this into
  the defect it is guarding against, because a check that silently answers
  "clean" when it could not look is worse than no check.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Qa.Evidence

  setup do
    {:ok, root} = Briefly.create(directory: true)
    submodule = Path.join(root, ".code_my_spec")
    File.mkdir_p!(Path.join(submodule, "qa/874"))

    git!(submodule, ["init", "--quiet"])
    git!(submodule, ["config", "user.email", "test@example.com"])
    git!(submodule, ["config", "user.name", "Test"])

    %{env: Environment.new(:local, root), submodule: submodule}
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end

  defp write_brief(submodule, story_id, body \\ "# brief\n") do
    File.write!(Path.join(submodule, "qa/#{story_id}/brief.md"), body)
  end

  describe "committed?/2" do
    test "an untracked brief is uncommitted", %{env: env, submodule: submodule} do
      write_brief(submodule, 874)

      assert {:uncommitted, paths} = Evidence.committed?(env, 874)
      assert "qa/874/brief.md" in paths
    end

    test "a committed brief passes", %{env: env, submodule: submodule} do
      write_brief(submodule, 874)
      git!(submodule, ["add", "."])
      git!(submodule, ["commit", "--quiet", "-m", "evidence"])

      assert :ok = Evidence.committed?(env, 874)
    end

    test "a committed brief edited afterwards is uncommitted again", %{
      env: env,
      submodule: submodule
    } do
      write_brief(submodule, 874)
      git!(submodule, ["add", "."])
      git!(submodule, ["commit", "--quiet", "-m", "evidence"])

      write_brief(submodule, 874, "# brief, revised\n")

      assert {:uncommitted, paths} = Evidence.committed?(env, 874)
      assert "qa/874/brief.md" in paths
    end

    # `hex_docs/` churns constantly in this submodule and belongs to nobody. A
    # gate that fired on it would fire on every QA pass, for a reason its reader
    # cannot act on — which is how gates get ignored.
    test "dirt outside the story's directory is not this story's problem", %{
      env: env,
      submodule: submodule
    } do
      write_brief(submodule, 874)
      git!(submodule, ["add", "."])
      git!(submodule, ["commit", "--quiet", "-m", "evidence"])

      File.mkdir_p!(Path.join(submodule, "hex_docs"))
      File.write!(Path.join(submodule, "hex_docs/phoenix.md"), "churn\n")
      File.mkdir_p!(Path.join(submodule, "qa/880"))
      write_brief(submodule, 880)

      assert :ok = Evidence.committed?(env, 874)
    end

    test "no working copy is unknown, never ok" do
      assert {:unknown, :no_working_copy} = Evidence.committed?(nil, 874)
    end

    # A harness environment answers `{:error, :not_supported_on_harness}` to any
    # `cmd` — `analysis/run` owns running commands there. That is a transport
    # limit, and reading it as "git said nothing, so nothing is dirty" is the
    # exact shape this module exists to prevent, one level up.
    test "a harness environment is unknown, never ok" do
      env = Environment.new(:harness, harness_id: Ecto.UUID.generate())

      assert {:unknown, _reason} = Evidence.committed?(env, 874)
    end

    test "a directory that is not a git repository is unknown, never ok" do
      {:ok, root} = Briefly.create(directory: true)
      File.mkdir_p!(Path.join(root, ".code_my_spec/qa/874"))

      assert {:unknown, _reason} = Evidence.committed?(Environment.new(:local, root), 874)
    end
  end

  describe "refusal/2" do
    test "names the paths and the commands, in order" do
      text = Evidence.refusal(874, ["qa/874/brief.md", "qa/874/screenshots/one.png"])

      assert text =~ "qa/874/brief.md"
      assert text =~ "git -C .code_my_spec add qa/874"
      assert text =~ "git -C .code_my_spec commit"
      assert text =~ "git -C .code_my_spec push"

      assert text =~ "refuses the claim, not the result",
             "the QA work is done and recorded; what is missing is the evidence " <>
               "being saved, and a reader who thinks their pass was thrown away " <>
               "will redo the whole thing"
    end

    test "truncates a long list rather than dumping every screenshot" do
      paths = for n <- 1..25, do: "qa/874/screenshots/#{n}.png"
      text = Evidence.refusal(874, paths)

      assert text =~ "… and 15 more"
    end
  end

  describe "unknown_note/1" do
    test "the harness case reads as expected, not as a retry signal" do
      note = Evidence.unknown_note(:not_supported_on_harness)

      assert note =~ "not independently verified"
      assert note =~ "expected, not"
      assert note =~ "qa/<story_id>"
    end

    test "any other reason says it could not check, rather than implying it did" do
      note = Evidence.unknown_note(:no_working_copy)

      assert note =~ "not verified"
      assert note =~ "no working copy"
    end
  end
end
