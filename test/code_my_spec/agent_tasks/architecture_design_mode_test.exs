defmodule CodeMySpec.AgentTasks.ArchitectureDesignModeTest do
  @moduledoc """
  The mode follows the architecture, not the artifact that first described it.

  `proposal.md`'s presence was the entire decision, so a project with 910
  components and no proposal on disk was handed initial mode — "No proposal
  exists yet. Design the architecture end-to-end" — eleven lines below "The
  project has 910 existing components". The evaluator then executes what comes
  back as one transaction, so an agent following its prompt either omits most
  of the project or reshapes it.

  That file is an artifact of how the architecture was *first* produced. A
  project with components has been designed; whether anyone kept, or ever
  wrote, or has since deleted the proposal that designed it is a different
  question, and it is not the one the mode is asking.

  The asymmetry is why the fallback leans the way it does: guessing "revision"
  costs an agent that makes no incremental edits, guessing "initial" costs a
  mass rewrite of a project nobody asked to redesign.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Environments.Environment

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    %{scope: scope, tmp: tmp}
  end

  # A lookup, not a branch: `SpexDeniedCalls` refuses imperative branching in a
  # test file because it usually means the test is reacting to state it should
  # control. This one only reads a rendered prompt, but a table says the same
  # thing without the shape that hides the other kind.
  #
  # `:neither` is a real answer rather than a fallback — a prompt carrying no
  # mode header at all is a distinct failure from carrying the wrong one, and
  # collapsing them would let a template that stopped rendering the header pass
  # as "not the mode I asserted".
  @mode_headers [{"## Mode — revision", :revision}, {"## Mode — initial", :initial}]

  defp mode(prompt) do
    @mode_headers
    |> Enum.find({nil, :neither}, fn {header, _mode} -> String.contains?(prompt, header) end)
    |> elem(1)
  end

  describe "a project that already has an architecture" do
    test "is revised, even with no proposal on disk", ctx do
      component_fixture(ctx.scope)

      {:ok, prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

      assert mode(prompt) == :revision,
             "components exist, so there is an architecture to revise — whatever " <>
               "became of the file that first described it"
    end

    test "is not told to design end-to-end and have the result executed", ctx do
      component_fixture(ctx.scope)

      {:ok, prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

      refute prompt =~ "No proposal exists yet",
             "the sentence that sat eleven lines under the component count"

      refute prompt =~ "Design the architecture end-to-end"
    end

    test "the prompt does not contradict itself about whether anything exists", ctx do
      # The report's actual complaint. Both statements were true of the same
      # prompt, and only one of them could be acted on.
      for _ <- 1..3, do: component_fixture(ctx.scope)

      {:ok, prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

      assert prompt =~ "3 existing components"
      assert mode(prompt) == :revision
    end
  end

  describe "a project with no components" do
    test "and no proposal is genuinely initial", ctx do
      {:ok, prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

      assert mode(prompt) == :initial,
             "nothing has been designed and there is nothing to patch — this is the " <>
               "one case the old rule got right, and it must keep working"
    end

    test "but with a proposal on disk is a revision", ctx do
      File.mkdir_p!(Path.join(ctx.tmp, ".code_my_spec/architecture"))
      File.write!(Path.join(ctx.tmp, ".code_my_spec/architecture/proposal.md"), "# Proposal\n")

      {:ok, prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

      assert mode(prompt) == :revision,
             "the file still means `there is a proposal to patch` — it just never " <>
               "again means `there is an architecture`"
    end
  end
end
