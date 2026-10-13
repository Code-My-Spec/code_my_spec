defmodule CmsHarnessTest.LiveHarness do
  @moduledoc """
  The harness half of a hook driven end to end: a checkout on disk, served by
  the real `CmsHarness` subtree, whose `ChannelClient` dials a real cloud
  endpoint over a real websocket.

  Nothing in between is a stand-in. A hook is posted to
  `CmsHarness.Web.Endpoint` at the address onboarding writes into the plugin's
  `hooks.json`; the harness forwards it as `hook_decision` over its Slipstream
  socket; the cloud's `HarnessProjectChannel` decides it, and every file it
  reads on the way goes back over the same socket as `fs_request` and is
  answered from this checkout by the harness, as in production.

  The cloud side — which endpoint listens, and which project and credentials
  exist — belongs to `CodeMySpecSpex.HarnessHooks`, because `CmsHarnessTest`
  may not reach the cloud app and a spex may not reach `CmsHarness`.
  """

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Channel
  alias CmsHarness.Project.ChannelClient
  alias CmsHarnessTest.ConnectHeaders
  alias CmsHarnessTest.Projects
  alias Phoenix.ConnTest

  # Everything per copy rides in the checkout or in `ConnectHeaders`, keyed on
  # its root — no application or OS environment is set, so two copies served at
  # once by one node cannot see each other's settings. What the harness reads
  # globally on this path is read-only here: `:harness_token` (unset in test, so
  # the checkout's deploy key is the credential), the device identity file
  # (an id the cloud does not know attaches nothing; onboarding already gave the
  # copy its device), and `:harness_decision_timeout` (the suite's 1s).

  @doc """
  A checkout on disk, before onboarding: a copy of the run's template
  repository, with `.code_my_spec/config.yml` naming the project and `files`
  (`%{path => content}`) written into the working tree, uncommitted.

  Uncommitted is enough. The harness scans the working tree, not HEAD; the only
  thing it asks git is `rev-parse HEAD`, which the template's commit answers.
  A directory with no repository at all would answer for whatever repository
  happens to enclose it.
  """
  @spec checkout(map()) :: String.t()
  def checkout(%{project_id: project_id, account_id: account_id} = opts) do
    root = CodeMySpec.TempFile.dir("cms_harness_live")
    File.cp_r!(template(), root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    Projects.write(
      root,
      ".code_my_spec/config.yml",
      "project_id: #{project_id}\naccount_id: #{account_id}\n"
    )

    # The partition a checkout's analyzers would run in, recorded as onboarding
    # records it — `CmsHarnessTest.Projects.project_dir/1` does the same.
    Projects.write(
      root,
      ".claude/settings.local.json",
      Jason.encode!(%{
        "env" => %{"MIX_TEST_PARTITION" => "fixture#{System.unique_integer([:positive])}"}
      })
    )

    Enum.each(Map.get(opts, :files, %{}), fn {path, content} ->
      Projects.write(root, path, content)
    end)

    Path.expand(root)
  end

  # One repository per run, built with real git the first time a checkout is
  # asked for and copied after that. Three git calls per given, across every
  # hook spex, is the nested-subprocess load that produced phantom `killed`
  # failures on a contended box; three per run is not.
  #
  # Under a lock, because async tests ask for their first checkout at once.
  defp template do
    :global.trans({__MODULE__, :template}, fn ->
      case :persistent_term.get({__MODULE__, :template}, nil) do
        nil -> build_template()
        dir -> dir
      end
    end)
  end

  # Isolated from the machine's own config: a global signing key or hooks path
  # would make this fixture depend on whoever runs it.
  @vcs_config [
    "-c",
    "user.name=spex",
    "-c",
    "user.email=spex@example.com",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null"
  ]

  defp build_template do
    dir = CodeMySpec.TempFile.dir("cms_harness_live_template")
    Projects.write(dir, ".code_my_spec/config.yml", "project_id: template\n")
    Projects.write(dir, "lib/.gitkeep", "")
    Projects.write(dir, "test/.gitkeep", "")

    Projects.cmd!(dir, "git", @vcs_config ++ ["init", "--quiet", "--initial-branch=main"])
    Projects.cmd!(dir, "git", @vcs_config ++ ["add", "--all"])
    Projects.cmd!(dir, "git", @vcs_config ++ ["commit", "--quiet", "--message", "the checkout"])

    # Outlives every test that copies it, so it goes with the VM.
    System.at_exit(fn _status -> File.rm_rf(dir) end)
    :persistent_term.put({__MODULE__, :template}, dir)
    dir
  end

  @doc """
  Write what onboarding issued into the checkout's `.cms_harness.json`: the
  working copy id, the project, the deploy key the harness connects with, and
  the server that minted the id — which is the one this copy's channel dials.
  """
  @spec onboard(String.t(), map()) :: :ok
  def onboard(root, %{working_copy_id: id, project_id: project_id} = issued) do
    HarnessConfig.write(root, %{
      working_copy_id: id,
      project_id: project_id,
      root: root,
      deploy_key: issued.deploy_key,
      server_url: issued.server_url
    })
  end

  @doc """
  Start serving `root`, its socket carrying `user_agent` — the cloud test's SQL
  sandbox metadata, so the channel it reaches uses that test's connection.
  """
  @spec serve(String.t(), String.t()) :: :ok
  def serve(root, user_agent) do
    :ok = ConnectHeaders.put(root, user_agent)
    :ok = Projects.ensure_harness_supervisor_started()
    {:ok, _project} = Projects.ensure_started(root)
    :ok
  end

  @doc """
  Stop serving `root` — its channel, watcher and analysis queue — and wait for
  the registry to forget it.
  """
  @spec stop_serving(String.t()) :: :ok
  def stop_serving(root) do
    Projects.stop_project(root)
    ConnectHeaders.delete(root)
  end

  @doc """
  Scan `root` and send its manifest now — what the harness's watcher does once
  its debounce lapses. Asynchronous, and ignored by a client not joined, which
  rescans on rejoin.
  """
  @spec sync_now(String.t()) :: :ok
  def sync_now(root), do: Channel.request_sync(root)

  @doc """
  Report a finished analyzer run the way the harness's analysis queue does:
  `Channel.deliver_analysis_result/2`, which pushes `analysis_result`
  over the copy's socket for the cloud to convert and reconcile.

  `result` is the wire map `CmsHarness.Analysis.run/4` answers — see
  `CodeMySpecSpex.HarnessReports.result/3` for one built from a recording.
  """
  @spec deliver_analysis_result(String.t(), integer(), String.t(), map()) :: :ok
  def deliver_analysis_result(root, run_id, source, result) do
    Channel.deliver_analysis_result(root, %{
      "run_id" => run_id,
      "source" => source,
      "status" => "ok",
      "result" => result
    })
  end

  @doc """
  Report that the harness's analysis queue started a run — the commit it
  started on and whether the tree was clean — as the queue reports it:
  `Channel.deliver_analysis_started/2`.
  """
  @spec deliver_analysis_started(String.t(), integer(), String.t(), String.t()) :: :ok
  def deliver_analysis_started(root, run_id, source, commit) do
    Channel.deliver_analysis_started(root, %{
      "run_id" => run_id,
      "source" => source,
      "start_commit" => commit,
      "start_tree_dirty" => false
    })
  end

  @doc """
  Report that an agent this harness runs ended its turn, the way the harness
  reports every step of a turn: `ChannelClient.report_turn_event/3`, pushed
  as `agent_turn_event` over the copy's socket.
  """
  @spec end_turn(String.t(), String.t(), map()) :: :ok
  def end_turn(root, agent_id, event),
    do: ChannelClient.report_turn_event(root, agent_id, event)

  @doc """
  POST a hook to the harness, the way Claude Code's plugin does, and decode the
  decision.

  `/api/harnesses/<working_copy_id>/hooks/<hook>`, with the payload as the JSON
  body. The harness answers 200 for every decision, refusals included, so the
  status says nothing and the body is the answer.
  """
  @spec post_hook(String.t(), String.t(), map()) :: map()
  def post_hook(working_copy_id, hook, payload) do
    # The endpoint is in the harness tree. Without this a spex run on its own
    # found no endpoint, and passed only when an earlier spex had started it.
    :ok = CmsHarnessTest.Projects.ensure_harness_supervisor_started()

    ConnTest.build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> ConnTest.dispatch(
      CmsHarness.Web.Endpoint,
      :post,
      "/api/harnesses/#{working_copy_id}/hooks/#{hook}",
      Jason.encode!(payload)
    )
    |> ConnTest.json_response(200)
  end
end
