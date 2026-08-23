defmodule CodeMySpec.Analysis.QueueKeyTest do
  @moduledoc """
  The analysis queue serializes per working copy, not per project.

  It used to serialize per project, which on a machine running several
  worktrees of one project made them wait on each other for a build tree they
  do not share. Sweeps run 200-590s here, so the wait was minutes and it
  arrived as a stop refused `:no_reply` with a message about the server or the
  network.

  These assert the key itself rather than the timing, because a timing test for
  "these two did not queue" is a race dressed as a proof.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.ProjectServer

  defp scope(project_id, working_copy_id),
    do: %CodeMySpec.Users.Scope{
      active_project_id: project_id,
      active_working_copy_id: working_copy_id
    }

  describe "server_key/1" do
    test "two checkouts of one project get different queues" do
      project = Ecto.UUID.generate()

      refute Analysis.server_key(scope(project, Ecto.UUID.generate())) ==
               Analysis.server_key(scope(project, Ecto.UUID.generate()))
    end

    test "the same checkout gets one queue, so exunit and spex still take turns" do
      project = Ecto.UUID.generate()
      harness = Ecto.UUID.generate()

      assert Analysis.server_key(scope(project, harness)) ==
               Analysis.server_key(scope(project, harness))
    end

    test "a harness id given as a string and as a uuid name the same queue" do
      # The channel carries it as a string and the scope as a uuid; keying on
      # the raw term would silently give one checkout two queues.
      harness = Ecto.UUID.generate()
      project = Ecto.UUID.generate()

      assert Analysis.server_key(scope(project, harness)) ==
               Analysis.server_key(scope(project, to_string(harness)))
    end

    test "no harness falls back to the project" do
      project = Ecto.UUID.generate()

      assert Analysis.server_key(scope(project, nil)) == {:project, project}
    end

    test "different projects with no harness stay separate" do
      refute Analysis.server_key(scope(Ecto.UUID.generate(), nil)) ==
               Analysis.server_key(scope(Ecto.UUID.generate(), nil))
    end
  end

  describe "the registry" do
    test "two working copies of one project run their own servers at once" do
      project = Ecto.UUID.generate()
      a = Analysis.server_key(scope(project, Ecto.UUID.generate()))
      b = Analysis.server_key(scope(project, Ecto.UUID.generate()))

      {:ok, pid_a} = start_supervised({ProjectServer, {a, project}}, id: :a)
      {:ok, pid_b} = start_supervised({ProjectServer, {b, project}}, id: :b)

      assert pid_a != pid_b
      assert [{^pid_a, _}] = Registry.lookup(CodeMySpec.Analysis.Registry, a)
      assert [{^pid_b, _}] = Registry.lookup(CodeMySpec.Analysis.Registry, b)
    end
  end
end
