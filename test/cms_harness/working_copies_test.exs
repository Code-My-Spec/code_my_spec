defmodule CmsHarness.WorkingCopiesTest do
  @moduledoc """
  Resolving a harness id to a directory.

  Two sources, in order: a copy this harness is already serving knows its own
  root, and anything else is the server's to answer. There is deliberately no
  third — no directory on the request, no list of paths in the environment, no
  local record of working copies — because each of those was either a guess or
  a second copy of something the server owns.

  The server half is not exercised here; it needs a credential and a running
  server, and `CmsHarness.Web.McpControllerTest` already drives that transport
  against a real socket. What is covered is the half that answers without one,
  which is every hook after a copy's first.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects

  alias CmsHarness.WorkingCopies

  describe "a copy this harness is serving" do
    setup do
      project = project_dir()
      serve(project.root)
      on_exit(fn -> stop_project(project.root) end)

      %{project: project}
    end

    test "resolves by the id written in it", %{project: project} do
      assert WorkingCopies.root(project.harness_id) == {:ok, project.root}
    end

    test "appears in the set this harness knows about", %{project: project} do
      assert Map.get(WorkingCopies.all(), project.harness_id) == project.root
    end

    test "a different id does not resolve to it", %{project: project} do
      other = Ecto.UUID.generate()

      refute WorkingCopies.root(other) == {:ok, project.root},
             "what this replaced walked up from the request's directory until a " <>
               "mix.exs turned up, so an unonboarded copy adopted whichever " <>
               "project sat above it"
    end
  end

  describe "an id with nothing behind it" do
    test "does not resolve, and does not crash the lookup" do
      assert WorkingCopies.root(Ecto.UUID.generate()) == :unknown
    end

    test "an empty or malformed id never resolves" do
      for id <- ["", "   ", nil, 42] do
        assert WorkingCopies.root(id) == :unknown
      end
    end
  end
end
