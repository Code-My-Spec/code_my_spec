defmodule CodeMySpec.McpServers.Architecture.Tools.RegenerateProposalTest do
  @moduledoc """
  The half of the round trip that had no caller.

  `Proposal.from_markdown/2` turns the document into components and has a tool
  driving it. `ProposalProjector.project/1` turns components back into the
  document and was unreachable from anywhere — so a project with 910 components
  and no `proposal.md` could only get one by somebody writing it out by hand,
  and `ArchitectureDesign` called that state "no proposal exists yet, design the
  architecture end-to-end".
  """
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Architecture.Tools.RegenerateProposal
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "writes the current architecture to proposal.md" do
      {scope, tmp_dir} = scope_with_disk()
      component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      assert {:reply, response, _frame} = run(scope, %{confirm: true})
      assert response.isError == false

      written = File.read!(Path.join(tmp_dir, Paths.proposal_path()))
      assert written =~ "MyApp.Accounts"
      assert written =~ "## Contexts"
    end

    # The guard is the point: the database cannot reconstruct an unexecuted
    # proposal, so overwriting one has to be asked for rather than defaulted to.
    test "refuses without confirm, and says what would be lost" do
      {scope, tmp_dir} = scope_with_disk()
      path = Path.join(tmp_dir, Paths.proposal_path())
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# hand-written, not yet executed")

      assert {:reply, response, _frame} = run(scope, %{})
      assert response.isError == true
      assert response_text(response) =~ "confirm: true"

      assert File.read!(path) == "# hand-written, not yet executed",
             "a refusal must not have written anything"
    end

    # The first real call to this tool wrote `## Contexts` and
    # `## Surface Components` empty over a hand-written proposal that had 25
    # contexts in it, because the projector only looked at parentless components
    # and every context in this project hangs off the app's root namespace
    # anchor. `confirm: true` was given and honoured — consent is not a check on
    # the content, so the content is checked too.
    test "a context nested under a namespace anchor reaches the document" do
      {scope, tmp_dir} = scope_with_disk()
      path = Path.join(tmp_dir, Paths.proposal_path())
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# the good one")

      # The shape that broke it, and the shape this project actually has: every
      # one of its 45 contexts hangs off `CodeMySpec`, so none is parentless.
      anchor = component_fixture(scope, %{module_name: "MyApp", type: "module"})

      component_fixture(scope, %{
        module_name: "MyApp.Accounts",
        type: "context",
        parent_component_id: anchor.id
      })

      assert {:reply, response, _frame} = run(scope, %{confirm: true})
      assert response.isError == false

      written = File.read!(path)

      assert written =~ "### MyApp.Accounts",
             "a nested context is still a context — depth describes how a module is " <>
               "named, not what it is"

      refute written == "# the good one"
    end

    # Same shape `create_component` uses when it cannot write: hand back the
    # content rather than reporting success over a file that does not exist.
    test "returns the content inline when it cannot write" do
      scope = %{full_scope_fixture() | environment: nil}

      assert {:reply, response, _frame} = run(scope, %{confirm: true})
      assert response_text(response) =~ "Not Written"
      assert response_text(response) =~ "```markdown"
    end
  end

  defp run(scope, params) do
    RegenerateProposal.execute(params, %Frame{assigns: %{current_scope: scope}})
  end

  defp scope_with_disk do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    Environments.ensure_dir(scope.environment, Path.dirname(Paths.proposal_path()))

    {scope, tmp_dir}
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
