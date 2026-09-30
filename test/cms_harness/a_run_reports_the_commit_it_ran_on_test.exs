defmodule CmsHarness.ARunReportsTheCommitItRanOnTest do
  @moduledoc """
  The harness tells the server which commit a run started on, whether the tree
  was clean then, and which commit it finished on.

  The analyzers run on the machine holding the checkout, so only this side can
  read `git`. Scripted git through the in-memory environment; a fake channel
  registered where `ChannelClient` looks one up by root.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Analysis
  alias CmsHarness.Project.AnalysisServer
  alias CodeMySpec.Support.InMemoryEnvironment

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  defp git(head, status) do
    {:ok, env} =
      InMemoryEnvironment.create(
        shell: fn
          "git", ["rev-parse", "HEAD"], _opts -> head
          "git", ["status", "--porcelain" | _], _opts -> status
        end
      )

    env
  end

  describe "tree_state/1" do
    test "a clean tree at a commit" do
      assert Analysis.tree_state(git({@sha_a <> "\n", 0}, {"", 0})) ==
               %{commit: @sha_a, dirty: false}
    end

    test "uncommitted changes read as dirty" do
      assert Analysis.tree_state(git({@sha_a <> "\n", 0}, {" M lib/a.ex\n", 0})) ==
               %{commit: @sha_a, dirty: true}
    end

    test "git that cannot answer says nothing rather than guessing" do
      assert Analysis.tree_state(git({"fatal: not a git repository", 128}, {"fatal", 128})) ==
               %{commit: nil, dirty: nil}
    end
  end

  defp fake_channel do
    root = "commit-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    root
  end

  defp state(root, running) do
    %{project: %{root: root}, running: running, queue: [], timer: nil}
  end

  test "a started run reports its commit and tree for itself and every run tied to it" do
    root = fake_channel()
    running = %{run_id: 7, source: "exunit", tied_run_ids: [8], task: nil}

    AnalysisServer.handle_info(
      {:analysis_started, 7, %{commit: @sha_a, dirty: true}},
      state(root, running)
    )

    for run_id <- [7, 8] do
      assert_receive {:"$gen_cast",
                      {:analysis_started,
                       %{
                         "run_id" => ^run_id,
                         "source" => "exunit",
                         "start_commit" => @sha_a,
                         "start_tree_dirty" => true
                       }}}
    end
  end

  test "a start for a run no longer executing is not reported" do
    root = fake_channel()
    running = %{run_id: 9, source: "exunit", tied_run_ids: [], task: nil}

    AnalysisServer.handle_info(
      {:analysis_started, 7, %{commit: @sha_a, dirty: false}},
      state(root, running)
    )

    refute_receive {:"$gen_cast", {:analysis_started, _}}, 50
  end

  test "a finished run's result carries the commit it finished on" do
    root = fake_channel()
    task = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {:erlang, :apply, 2}}
    running = %{run_id: 7, source: "compiler", tied_run_ids: [], task: task}

    result = %{"source" => "compiler", "exit_status" => 0, "diagnostics" => []}

    AnalysisServer.handle_info(
      {task.ref, {:ran, {:ok, result}, %{commit: @sha_b, dirty: false}}},
      state(root, running)
    )

    assert_receive {:"$gen_cast",
                    {:analysis_result,
                     %{"run_id" => 7, "status" => "ok", "completed_commit" => @sha_b}}}
  end
end
