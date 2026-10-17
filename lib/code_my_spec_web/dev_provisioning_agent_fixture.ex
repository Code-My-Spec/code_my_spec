defmodule CodeMySpecWeb.DevProvisioningAgentFixture do
  @moduledoc "Development-only preparation of an isolated, real QA harness."

  alias CodeMySpec.{Devices, Projects, WorkingCopies}
  alias CodeMySpec.Provisioning.QaFixture

  @enabled Application.compile_env(:code_my_spec, :dev_routes, false)

  # The dedicated harness reads this straight into `:harness_token`
  # (`CmsHarness.Credentials.from_user_token/0`), which bypasses the deploy-key
  # exchange `CmsHarness.Token` otherwise refreshes on expiry -- so once this
  # token expires, every later MCP session 401s with nothing to recover it
  # short of preparing a fresh fixture. `qa_963_harness.exs` says to "keep this
  # process running during QA"; the old 3600s (1h) expiry could not survive an
  # ordinary manual QA session (c79fb8f9). 12h mirrors `SpriteTokenController`'s
  # own precedent for exactly this "nothing refreshes it" reasoning.
  @expires_in 12 * 60 * 60

  def prepare(scope, project, server_url)
      when @enabled and is_map(scope) and is_map(project) and is_binary(server_url) do
    uri = URI.parse(server_url)

    with true <- uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"],
         {:ok, _} <- QaFixture.snapshot(project.id),
         true <- project.account_id == scope.active_account_id,
         true <- is_nil(project.local_path) or project.local_path == "" do
      scope = %{scope | active_project: project, active_project_id: project.id}
      prepare_new(scope, project, server_url)
    else
      _ -> {:error, :invalid_or_already_prepared_fixture}
    end
  end

  def prepare(_, _, _), do: {:error, :disabled}

  defp prepare_new(scope, project, server_url) do
    directory = Path.join(System.tmp_dir!(), "qa963-#{Ecto.UUID.generate()}")
    root = Path.join(directory, "project")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    File.mkdir_p!(Path.join(root, ".code_my_spec/spec"))
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "lib/qa_setup.ex"),
      "defmodule QaSetup do\n  @moduledoc \"Disposable story 963 provisioning fixture.\"\nend\n"
    )

    with {:ok, device} <-
           Devices.announce(scope, Ecto.UUID.generate(), %{
             hostname: "qa963-fixture",
             kind: :local
           }),
         {:ok, copy} <- WorkingCopies.issue(scope, nil, device: device.id, root: root),
         {:ok, copy} <- WorkingCopies.report_root(copy, root),
         {:ok, _} <- WorkingCopies.designate_main(scope, copy.id),
         {:ok, _} <- Projects.update_project(scope, project, %{local_path: root}),
         {:ok, token} <-
           ExOauth2Provider.AccessTokens.create_token(
             scope.user,
             %{expires_in: @expires_in},
             otp_app: :code_my_spec
           ) do
      write_private(Path.join(directory, "device.json"), %{device_id: device.id})

      write_private(Path.join(root, ".cms_harness.json"), %{
        working_copy_id: copy.id,
        harness_id: copy.id,
        project_id: project.id,
        root: root,
        server_url: server_url
      })

      File.write!(Path.join(root, ".gitignore"), ".cms_harness.json\n")

      File.write!(
        Path.join(root, "README.md"),
        "# Story 963 QA fixture\n\nDisposable provisioning simulator. No real infrastructure is authorized.\n"
      )

      runtime_path = Path.join(directory, "runtime.json")

      write_private(runtime_path, %{
        fixture: "story-963",
        project_id: project.id,
        working_copy_id: copy.id,
        root: root,
        server_url: server_url,
        token: token.token
      })

      {:ok,
       %{
         project_id: project.id,
         working_copy_id: copy.id,
         root: root,
         runtime_path: runtime_path,
         expires_in: @expires_in
       }}
    end
  end

  defp write_private(path, value) do
    File.write!(path, Jason.encode!(value))
    File.chmod!(path, 0o600)
  end
end
