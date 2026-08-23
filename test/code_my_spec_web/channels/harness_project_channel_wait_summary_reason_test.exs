defmodule CodeMySpecWeb.HarnessProjectChannel.WaitSummaryReasonTest do
  @moduledoc """
  A failed analyzer says why, on the line that says it failed.

  `- exunit: failed, 0 problem(s)` is what `analysis/wait` answered for three
  consecutive calls while `mix test` ran clean in the same checkout. It is
  indistinguishable from a crashed analyzer, a killed process, or a loaded
  machine — and the machine was loaded, so the agent attributed it to
  contention and kept stopping against green local runs.

  The reason was one string away. The analyzer's own partition was two
  migrations behind, the server rejected the result saying exactly that, and
  `Reconciler.fail/2` persisted it to `stats["error"]`. `Analysis.status/1` has
  always returned the run alongside the state. The summary line simply never
  read it, so the message reached `harness.log` and nowhere an agent looks
  (`d1f74ee7`, story 890 — where an undelivered result *is* the defect).
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @label "the harness at /workspace/app"
  @behind "** (RuntimeError) The test database `code_my_spec_testhac99571fa` is 2 migration(s) behind."

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    %{scope: scope, topic: "harness_project:#{scope.active_project_id}"}
  end

  defp join_as(scope, topic) do
    {:ok, _reply, socket} =
      UserSocket
      |> socket("harness_test", %{scope: scope})
      |> subscribe_and_join(HarnessProjectChannel, topic, %{
        "label" => @label,
        "harness_id" => scope.active_working_copy_id
      })

    socket
  end

  defp failed_run(scope, source, error) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: source,
        kind: :full,
        input_fingerprint: "whatever"
      })

    {:ok, _} = RunsRepository.finish_run(run, :failed, %{stats: %{"error" => error}})
  end

  defp summary(scope, topic) do
    ref = scope |> join_as(topic) |> push("analysis_wait", %{})
    assert_reply ref, :ok, %{"summary" => summary}, 30_000
    summary
  end

  test "a rejected result names its cause in the summary", %{scope: scope, topic: topic} do
    failed_run(scope, "exunit", @behind)

    summary = summary(scope, topic)

    assert summary =~ "exunit: failed", "the state is still reported. Got:\n#{summary}"

    assert summary =~ "2 migration(s) behind",
           """
           An agent reading `failed, 0 problem(s)` cannot tell a stale analyzer
           database from a crash or a loaded machine, and the difference decides
           whether it fixes something or waits. The sentence naming the cause is
           already on the run.

           Got:
           #{summary}
           """
  end

  test "a run that failed without a recorded reason still renders", %{scope: scope, topic: topic} do
    failed_run(scope, "exunit", "")

    summary = summary(scope, topic)

    assert summary =~ "exunit: failed",
           "an empty reason must not swallow the line it was meant to explain"

    refute summary =~ "\n    \n",
           "an empty reason should add nothing, not a blank indented line"
  end

  test "a stacktrace is cut to its first line", %{scope: scope, topic: topic} do
    failed_run(
      scope,
      "exunit",
      @behind <> "\n    (ecto 3.13.2) lib/ecto/migrator.ex:1: Ecto.Migrator.run/4"
    )

    summary = summary(scope, topic)

    assert summary =~ "2 migration(s) behind"

    refute summary =~ "Ecto.Migrator.run/4",
           "a summary that scrolls is one nobody reads; these tools put the " <>
             "sentence that names the cause on the first line"
  end
end
