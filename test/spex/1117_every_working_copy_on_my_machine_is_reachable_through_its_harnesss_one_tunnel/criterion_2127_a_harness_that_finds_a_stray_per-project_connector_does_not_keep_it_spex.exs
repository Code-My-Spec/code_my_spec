defmodule CodeMySpecSpex.Story1117.Criterion2127Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2127 — A harness that finds a stray per-project connector does not keep it.

  Rule: A machine's harness runs exactly one tunnel, however many projects and
  working copies it serves.

  Driven on the harness itself, through the app-instance rig: the copy is
  first handed its project's old per-project tunnel (what a main copy holds
  today), then the machine's tunnel. Connectors are the fake runner's, which
  records each one started and stopped instead of launching `cloudflared`.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  @old_tunnel %{
    "tunnel_id" => "project-tunnel-2127",
    "tunnel_secret" => "b2xk",
    "account_tag" => "test-account",
    "hostname" => "preview-old-2127.codemyspec.com"
  }

  @machine_tunnel %{
    "tunnel_id" => "machine-tunnel-2127",
    "tunnel_secret" => "bWFjaGluZQ==",
    "account_tag" => "test-account",
    "hostname" => "preview-new-2127.codemyspec.com"
  }

  spex "A harness that finds a stray per-project connector does not keep it", criterion: 2127 do
    scenario "the machine tunnel replaces a project's old connector" do
      given_ "a project's old per-project tunnel connector is still running on the Mac",
             context do
        rig = app_instance_rig(database_exists?: true)

        assert %{"status" => "ok"} =
                 push_app_event_with("ensure_app_running", %{
                   "main" => true,
                   "tunnel" => @old_tunnel
                 })

        {:ok, Map.merge(context, rig)}
      end

      when_ "the harness is handed its machine's tunnel", context do
        result =
          push_app_event_with("restart_app", %{"main" => true, "tunnel" => @machine_tunnel})

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the old connector is no longer running, and the machine's is", context do
        tunnel_calls =
          Enum.filter(
            FakeAppInstanceRunner.calls(),
            &match?({call, _} when call in [:start_tunnel, :stop_tunnel], &1)
          )

        started =
          for {:start_tunnel, [credentials, _origin]} <- tunnel_calls, do: tunnel_id(credentials)

        stopped = Enum.count(tunnel_calls, &match?({:stop_tunnel, _}, &1))

        assert List.last(started) == "machine-tunnel-2127",
               "the machine's tunnel was never started; started: #{inspect(started)}"

        assert length(started) - stopped == 1,
               "#{length(started)} connectors started and #{stopped} stopped — the old " <>
                 "per-project connector is still running beside the machine's"

        {:ok, context}
      end
    end
  end

  defp tunnel_id(%{tunnel_id: id}), do: id
  defp tunnel_id(%{"tunnel_id" => id}), do: id
end
