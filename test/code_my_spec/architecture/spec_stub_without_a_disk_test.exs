defmodule CodeMySpec.Architecture.SpecStubWithoutADiskTest do
  @moduledoc """
  Where a component's stub spec goes when the server has no working copy.

  The answer used to be: into the server's own repository. `write_for_scope/2`
  built a `:cli` environment rooted at `File.cwd!()` when the scope had none,
  and drill 7 left eight `e2e_todo` spec files in the code_my_spec checkout.

  The damage was on the other side. Dependency edges are read out of spec files,
  so the container's empty spec directory meant no component had edges, every
  component read as an orphan, and `architecture_designed` could not pass — while
  the agent had done everything correctly and nothing in any reply said
  otherwise.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Architecture.SpecStub

  @component %{
    module_name: "MyApp.Widgets",
    type: :context,
    description: "Stores widgets.",
    dependencies: ["MyApp.Repo"]
  }

  test "refuses rather than writing somewhere it was not asked to" do
    assert SpecStub.write_for_scope(%{environment: nil, cwd: nil}, @component) ==
             {:error, :no_working_copy}
  end

  test "a cwd on the scope is not permission to use the server's disk" do
    # `scope.cwd` is a *client's* directory. The old fallback treated it, and
    # then File.cwd!(), as somewhere to write.
    assert SpecStub.write_for_scope(%{environment: nil, cwd: "/some/agents/project"}, @component) ==
             {:error, :no_working_copy}
  end

  test "renders what to write and where, for whoever does have the disk" do
    assert {path, body} = SpecStub.render(@component)

    assert path =~ "widgets.spec.md"
    assert body =~ "# MyApp.Widgets"
    assert body =~ "context"

    assert body =~ "MyApp.Repo",
           "dependencies are the reason the stub matters — without them the " <>
             "component is an orphan and the architecture requirement cannot pass"
  end
end
