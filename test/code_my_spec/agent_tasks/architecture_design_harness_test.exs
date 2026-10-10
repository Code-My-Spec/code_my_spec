defmodule CodeMySpec.AgentTasks.ArchitectureDesignHarnessTest do
  @moduledoc """
  A missing proposal on a harness is missing, not unreadable.

  The far side's `{:error, :enoent}` came back over `fs_result` as `"enoent"`,
  so `proposal_status/1` read it as `:unobservable` and every harness project
  with no components was put in revision mode, and an evaluate with no proposal
  reported "Proposal parse error: enoent" (8e3669fc).

  The channel here is a registered process that answers with the harness's own
  encoder and the server's own decoder, through JSON, against a real disk.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpecWeb.HarnessProjectChannel

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("test")
    id = a_harness_serving(tmp)

    env = %Environment{type: :harness, cwd: tmp, ref: %{"harness_id" => id}}

    scope = %{working_copy_scope_fixture() | cwd: tmp, environment: env}
    :ok = register_working_copy_environment(scope, env)
    %{scope: scope}
  end

  test "a project with no components and no proposal is initial", ctx do
    {:ok, prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

    assert prompt =~ "## Mode — initial"
    refute prompt =~ "## Mode — revision"
  end

  test "evaluating with no proposal says the proposal is missing", ctx do
    {:ok, _prompt} = ArchitectureDesign.command(ctx.scope, %{id: 1})

    assert {:ok, :invalid, feedback} = ArchitectureDesign.evaluate(ctx.scope, %{id: 1})
    assert feedback =~ "Proposal file not found"
  end

  defp a_harness_serving(root) do
    id = "fs-#{System.unique_integer([:positive])}"
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(HarnessRegistry, id, {"test", root})
        send(test, {:registered, id})
        serve(Environment.new(:local, root))
      end)

    assert_receive {:registered, ^id}, 2_000
    on_exit(fn -> Process.exit(pid, :kill) end)
    id
  end

  defp serve(local) do
    receive do
      {:"$gen_call", from, {:fs_request, op, payload}} ->
        reply =
          local
          |> apply_op(op, payload)
          |> ChannelClient.encode_fs_result()
          |> Jason.encode!()
          |> Jason.decode!()
          |> HarnessProjectChannel.decode_fs_result()

        GenServer.reply(from, reply)
        serve(local)
    end
  end

  defp apply_op(env, "stat", %{"path" => p}), do: Environments.stat(env, p)
  defp apply_op(env, "read_file", %{"path" => p}), do: Environments.read_file(env, p)
  defp apply_op(env, "delete_file", %{"path" => p}), do: Environments.delete_file(env, p)
  defp apply_op(env, "list_directory", %{"path" => p}), do: Environments.list_directory(env, p)

  defp apply_op(env, "write_file", %{"path" => p, "content" => c}),
    do: Environments.write_file(env, p, c)
end
