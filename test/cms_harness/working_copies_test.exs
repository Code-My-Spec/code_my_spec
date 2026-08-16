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

  # Async, on an invariant rather than on hope — this asserts on the *absence*
  # of a credential, which is node-global state.
  #
  # `root/1` returns `{:unreachable, _}` here only because the environment has
  # no `CMS_TOKEN`, and OS environment variables belong to the node rather than
  # to a test process. What made that unsafe was `CmsHarnessTest.ConnCase`,
  # which clears and restores those variables in its setup.
  #
  # Every file that mutates `CMS_*` is now sync, and `ConnCase` raises at
  # compile time if anyone passes `async: true` to it. ExUnit finishes the
  # async phase before the sync one begins, so nothing is touching these
  # variables while this runs. That is what makes it safe — not that it
  # happens to pass, which it also did before, alone.
  #
  # The other half is unchanged and is not about concurrency: under the
  # analyzer, `mix test` inherits an exported `CMS_TOKEN` from the harness, and
  # then this file's premise is false no matter what the flag says. That is
  # what `ConnCase` clearing the variables for every test exists to prevent.
  use ExUnit.Case, async: true

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
    # Not `:unknown`, and the difference is the point. `:unknown` means the
    # server was asked and said no, which re-onboarding fixes. This test env has
    # no credential, so the token exchange fails and the server is never asked —
    # the id is not implicated and onboarding would fix nothing.
    #
    # Both used to answer `:unknown`, and the hook refusal built on it told the
    # reader "the server does not recognise this id, re-run
    # `mix cms.harness.onboard`" on a perfectly good id while `:4000` was down.
    test "says it could not ask, rather than blaming the id, when the server is unreachable" do
      assert {:unreachable, _reason} = WorkingCopies.root(Ecto.UUID.generate())
    end

    # The claim is that none of these resolves — not which flavour of refusal
    # each gets. `root/1`'s guard rejects `""`, `nil` and `42` outright without
    # asking anyone; `"   "` passes it (`is_binary(id) and id != ""`) and gets
    # asked about, so it comes back `{:unreachable, _}` here rather than
    # `:unknown`. Worth knowing — a whitespace id reaching the network is not
    # useful — but the guarantee this test exists for is that no malformed id
    # ever produces a root.
    test "an empty or malformed id never resolves" do
      for id <- ["", "   ", nil, 42] do
        refute match?({:ok, _root}, WorkingCopies.root(id)),
               "#{inspect(id)} must never resolve to a working copy"
      end
    end
  end
end
