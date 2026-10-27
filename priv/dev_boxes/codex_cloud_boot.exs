# Executed by the installed Linux harness release, never by the target project.
defmodule CodexCloudBoot do
  def run do
    state = System.fetch_env!("CMS_CLOUD_STATE_DIR")
    root = System.fetch_env!("CMS_CLOUD_PROJECT_ROOT") |> Path.expand()
    context = state |> Path.join("config.json") |> File.read!() |> Jason.decode!()
    server = String.trim_trailing(context["server_url"], "/")
    credential_dir = Path.join(state, "harness")
    File.mkdir_p!(credential_dir)
    File.chmod!(credential_dir, 0o700)
    System.put_env("CMS_STATE_DIR", credential_dir)
    System.put_env("CMS_SERVER_URL", server)
    System.put_env("CMS_PROJECT_DIR", root)

    unless CodeMySpec.Paths.local_state_dir() == credential_dir,
      do:
        raise(
          "Installed harness predates Codex Cloud support; set CMS_HARNESS_VERSION to a release with CMS_STATE_DIR and proxy socket support, rerun setup, then startup"
        )

    opts = [state_dir: credential_dir]
    Application.put_env(:code_my_spec, CodeMySpec.Auth.HarnessOAuth, opts)
    Application.put_env(:code_my_spec, :project_id, context["project_id"])
    CmsHarness.Proxy.install!()

    {:ok, _} = Application.ensure_all_started(:req)
    seed_device(credential_dir, context["device_id"])
    token = authorize(server, context["device_id"], opts, state)
    {:ok, announced} = CmsHarness.Device.announce(%{}, token)

    unless announced.device_id == context["device_id"],
      do: raise("Server returned a different device identity")

    id = working_copy(root, context, token, announced.working_copies)
    app = app_name(root)

    ClientUtils.Harness.Onboarding.onboard(root,
      harness_id: id,
      app: app,
      base_url: local_url(),
      server_url: server
    )

    {:ok, _} = Application.ensure_all_started(:code_my_spec)
    :ok = CmsHarness.Projects.ensure_started(root) |> started()
    write_status(state, %{phase: "authorized"})
    Process.sleep(:infinity)
  end

  defp started({:ok, _}), do: :ok
  defp started(other), do: raise("Harness could not serve the project: #{inspect(other)}")
  defp local_url, do: "http://127.0.0.1:" <> (System.get_env("CMS_HARNESS_PORT") || "4004")

  defp seed_device(dir, id) do
    path = Path.join(dir, "device.json")

    case File.read(path) do
      {:ok, contents} ->
        unless Jason.decode!(contents)["device_id"] == id,
          do: raise("State directory belongs to a different dev box")

      {:error, :enoent} ->
        File.write!(path, Jason.encode!(%{device_id: id}))
        File.chmod!(path, 0o600)

      {:error, _} ->
        raise("Cannot read dev box identity")
    end
  end

  defp authorize(server, device_id, opts, state) do
    case CodeMySpec.Auth.HarnessOAuth.access_token(server, opts) do
      {:ok, token} ->
        token

      {:error, reason} when reason in [:no_credential, :authorization_required] ->
        {:ok, grant} = CodeMySpec.Auth.HarnessOAuth.begin_authorization(server, device_id, opts)

        write_status(state, %{
          phase: "pending",
          verification_uri: grant.verification_uri,
          user_code: grant.user_code
        })

        poll(server, grant, opts)

      {:error, _} ->
        raise("Device credentials could not be refreshed; check server access and retry startup")
    end
  end

  defp poll(server, grant, opts) do
    Process.sleep(grant.interval * 1000)

    case CodeMySpec.Auth.HarnessOAuth.poll(server, grant, opts) do
      {:ok, token} ->
        token

      {:error, :authorization_pending} ->
        poll(server, grant, opts)

      {:error, :slow_down} ->
        poll(server, %{grant | interval: grant.interval + 5}, opts)

      {:error, _} ->
        raise("Device authorization expired or was refused; rerun startup to request a new code")
    end
  end

  defp working_copy(root, context, token, copies) do
    project = context["project_id"]
    server = context["server_url"]

    case CmsHarness.HarnessConfig.read(root) do
      {:ok, %{working_copy_id: id, project_id: ^project, server_url: ^server}} ->
        unless Map.get(copies, id) == root,
          do:
            raise(
              "Checkout identity belongs to another device or path; remove the copied .cms_harness.json and rerun startup to register this box"
            )

        id

      :none ->
        mint(root, context, token)

      _ ->
        raise(
          "Checkout belongs to a different project/server or has invalid .cms_harness.json; resolve it before retrying"
        )
    end
  end

  defp mint(root, context, token) do
    {:ok, response} =
      Req.post(context["server_url"] <> "/api/harnesses",
        headers: [{"authorization", "Bearer " <> token}],
        retry: false,
        json: %{
          root: root,
          project_id: context["project_id"],
          device_id: context["device_id"],
          label: Path.basename(root)
        }
      )

    unless response.status == 200 and is_binary(response.body["harness_id"]),
      do: raise("Server refused working-copy registration (HTTP #{response.status})")

    id = response.body["harness_id"]

    :ok =
      CmsHarness.HarnessConfig.write(root, %{
        working_copy_id: id,
        project_id: context["project_id"],
        server_url: context["server_url"],
        root: root
      })

    id
  end

  defp app_name(root) do
    case Regex.run(~r/\bapp:\s*:([a-z][a-z0-9_]*)/, File.read!(Path.join(root, "mix.exs"))) do
      [_, app] -> app
      _ -> raise("Cannot determine the generated Phoenix app name from mix.exs")
    end
  end

  defp write_status(state, status) do
    path = Path.join(state, "authorization.json")
    File.write!(path, Jason.encode!(status))
    File.chmod!(path, 0o600)
  end
end

CodexCloudBoot.run()
