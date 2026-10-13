defmodule CmsHarness.AJoinTheServerNeverAnswersIsRetriedTest do
  @moduledoc """
  57aa576c: under load a harness's channel client sat connected and unjoined
  for a minute — `attempts: 0`, alive, never disconnected — because Slipstream
  times neither the websocket upgrade nor the join reply, and the reconnect
  backoff only runs from a disconnect.

  The far side here is `CmsHarnessTest.FakeServer` holding the join: the socket
  upgrades, the join is received, and no reply ever comes.
  """

  # Sync: `Projects.ensure_started/1` registers globally, and the join timeout
  # is application config.
  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects
  import ExUnit.CaptureLog

  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  setup do
    previous_project = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")

    previous_timeout = Application.get_env(:code_my_spec, :harness_join_timeout)
    Application.put_env(:code_my_spec, :harness_join_timeout, 300)

    project = project_dir()
    write(project.root, "lib/demo/accounts.ex", "defmodule Demo.Accounts do\nend\n")

    on_exit(fn ->
      stop_project(project.root)
      restore_env("CMS_PROJECT_ID", previous_project)
      restore_timeout(previous_timeout)
    end)

    %{project: project}
  end

  defp restore_env(_var, nil), do: :ok
  defp restore_env(var, value), do: System.put_env(var, value)

  defp restore_timeout(nil), do: Application.delete_env(:code_my_spec, :harness_join_timeout)

  defp restore_timeout(value),
    do: Application.put_env(:code_my_spec, :harness_join_timeout, value)

  test "a join the server never answers is given up and dialed again", %{project: project} do
    FakeServer.start(hold_joins: true)
    project_id = project.id

    log =
      capture_log(fn ->
        {:ok, _} = Projects.ensure_started(project.root)

        assert_receive {:join_held, ^project_id}, 5_000

        # Answered from here on, so the retry is what joins.
        FakeServer.hold_joins(false)

        assert_receive {:joined, ^project_id, _payload},
                       10_000,
                       "the client never dialed again after a join went unanswered — " <>
                         "it waits forever with no disconnect to retry from"

        assert_receive {:read_model_requested, ^project_id},
                       5_000,
                       "the retried join was answered but the client never took it as joined"
      end)

    assert log =~ "did not join harness_project:#{project_id}",
           "a stalled attempt has to say why it was dropped, or it reads as a flap"

    assert log =~ "the join was never answered"
  end
end
