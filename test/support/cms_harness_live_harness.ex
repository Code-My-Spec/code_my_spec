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
  alias CmsHarnessTest.Projects
  alias Phoenix.ConnTest

  # What a harness reads from the OS environment before it reads the checkout.
  # A spex run under the harness's own analyzer inherits all of them — and
  # `CMS_HARNESS_ID` alone would make this checkout answer to another copy's id.
  @environment_vars ~w(
    CMS_TOKEN CMS_DEPLOY_KEY CMS_SERVER_URL CMS_PROJECT_ID CMS_PROJECT_DIR CMS_HARNESS_ID
  )

  # Application env the harness reads, and what this sets each to.
  @app_env ~w(
    harness_server_url harness_server_url_override harness_token device_config_path
    harness_served_roots_dir harness_decision_timeout
  )a

  # Production's own. The suite's 1s exists for tests about the timeout firing;
  # a hook that reads files over the channel on a loaded box needs the real one,
  # or a slow answer reads as a dead channel.
  @decision_timeout 10_000

  @doc """
  A checkout on disk, before onboarding: `.code_my_spec/config.yml` naming the
  project, `files` (`%{path => content}`), and a git repository with all of it
  committed.

  A repository because the harness asks git for the checkout's HEAD on every
  sync, and a directory that is not one answers for whatever repository
  happens to enclose it.
  """
  @spec checkout(map()) :: String.t()
  def checkout(%{project_id: project_id, account_id: account_id} = opts) do
    %{root: root} = Projects.project_dir(project_id: project_id, working_copy_id: nil)

    Projects.write(
      root,
      ".code_my_spec/config.yml",
      "project_id: #{project_id}\naccount_id: #{account_id}\n"
    )

    Enum.each(Map.get(opts, :files, %{}), fn {path, content} ->
      Projects.write(root, path, content)
    end)

    commit_all!(root)
    Path.expand(root)
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

  defp commit_all!(root) do
    Projects.cmd!(root, "git", @vcs_config ++ ["init", "--quiet", "--initial-branch=main"])
    Projects.cmd!(root, "git", @vcs_config ++ ["add", "--all"])
    Projects.cmd!(root, "git", @vcs_config ++ ["commit", "--quiet", "--message", "the checkout"])
  end

  @doc """
  Write what onboarding issued into the checkout's `.cms_harness.json`: the
  working copy id, the project, and the deploy key the harness connects with.
  """
  @spec onboard(String.t(), map()) :: :ok
  def onboard(root, %{working_copy_id: id, project_id: project_id, deploy_key: key}) do
    HarnessConfig.write(root, %{
      working_copy_id: id,
      project_id: project_id,
      root: root,
      deploy_key: key
    })
  end

  @doc """
  What `serve/4` is about to change, for `restore/1` to put back.

  Taken first and on its own so a caller can register its teardown before
  anything starts — a join that fails must still be cleaned up.
  """
  @spec save_env() :: map()
  def save_env do
    %{
      os: Enum.map(@environment_vars, &{&1, System.get_env(&1)}),
      app: Enum.map(@app_env, &{&1, Application.fetch_env(:code_my_spec, &1)}),
      served_roots: CodeMySpec.TempFile.dir("live_harness_served_roots")
    }
  end

  @doc """
  Point this node's harness at `server_url` and start serving `root`.

  `device_file` is this machine's identity, kept out of `~/.codemyspec`;
  `saved` is `save_env/0`'s answer.
  """
  @spec serve(String.t(), String.t(), String.t(), map()) :: :ok
  def serve(root, server_url, device_file, %{served_roots: served_roots}) do
    Enum.each(@environment_vars, &System.delete_env/1)

    # The override as well as the plain key: `Config.server_url/0` ranks the
    # override above `CMS_SERVER_URL`, the plain key below it.
    Application.put_env(:code_my_spec, :harness_server_url, server_url)
    Application.put_env(:code_my_spec, :harness_server_url_override, server_url)
    # The checkout's own deploy key is the credential, as onboarding leaves it.
    # A user token would outrank it.
    Application.put_env(:code_my_spec, :harness_token, nil)
    Application.put_env(:code_my_spec, :device_config_path, device_file)
    # Restart hints go under the run's own temp dir, not `~/.codemyspec`. `mix
    # spex` loads no `test_helper.exs`, which is where `mix test` points this.
    Application.put_env(:code_my_spec, :harness_served_roots_dir, served_roots)
    Application.put_env(:code_my_spec, :harness_decision_timeout, @decision_timeout)

    :ok = Projects.ensure_harness_supervisor_started()
    {:ok, _project} = Projects.ensure_started(root)
    :ok
  end

  @doc """
  Stop serving `root` — its channel, watcher and analysis queue — and wait for
  the registry to forget it.
  """
  @spec stop_serving(String.t()) :: :ok
  def stop_serving(root), do: Projects.stop_project(root)

  @doc "Put back what `serve/3` changed."
  @spec restore(map()) :: :ok
  def restore(%{os: os, app: app, served_roots: served_roots}) do
    Enum.each(os, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    Enum.each(app, fn
      {key, :error} -> Application.delete_env(:code_my_spec, key)
      {key, {:ok, value}} -> Application.put_env(:code_my_spec, key, value)
    end)

    File.rm_rf(served_roots)
    :ok
  end

  @doc """
  POST a hook to the harness, the way Claude Code's plugin does, and decode the
  decision.

  `/api/harnesses/<working_copy_id>/hooks/<hook>`, with the payload as the JSON
  body. The harness answers 200 for every decision, refusals included, so the
  status says nothing and the body is the answer.
  """
  @spec post_hook(String.t(), String.t(), map()) :: map()
  def post_hook(working_copy_id, hook, payload) do
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
