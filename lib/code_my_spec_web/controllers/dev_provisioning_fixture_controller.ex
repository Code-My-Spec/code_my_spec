defmodule CodeMySpecWeb.DevProvisioningFixtureController do
  @moduledoc "Development-only disposable setup fixtures and simulated provider controls."
  use CodeMySpecWeb, :controller

  alias CodeMySpec.{
    Agents,
    Devices,
    Projects,
    UserPreferences,
    Users,
    WorkingCopies
  }

  alias ClientUtils.Harness.Onboarding
  alias CodeMySpec.Provisioning.QaFixture
  alias CodeMySpecWeb.QaEnvironments
  alias ExOauth2Provider.AccessTokens

  def create(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, project} <-
           Projects.create_project(scope, %{
             name: "QA Setup #{Ecto.UUID.generate()}",
             module_name: "QaSetup",
             domain: "setup-qa.invalid",
             setup_options: ~w(server domain email storage)
           }),
         :ok <- QaFixture.register(project.id, scope.active_account_id) do
      json(conn, %{
        project_id: project.id,
        account_id: scope.active_account_id,
        simulated: true,
        console_path: "/app/projects/#{project.id}/console"
      })
    else
      _ -> refuse(conn)
    end
  end

  def prepare_agent(conn, params) do
    origin = URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

    with {:ok, scope} <- authenticate(params),
         {:ok, project} <- Projects.get_project(scope, params["project_id"]),
         {:ok, fixture} <-
           CodeMySpecWeb.DevProvisioningAgentFixture.prepare(scope, project, origin) do
      json(conn, fixture)
    else
      _ -> refuse(conn)
    end
  end

  def start_agent(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, project} <- Projects.get_project(scope, params["project_id"]),
         {:ok, _} <- QaFixture.snapshot(project.id),
         {:ok, copy} <- CodeMySpec.WorkingCopies.fetch(params["working_copy_id"]),
         true <-
           copy.project_id == project.id and copy.main and
             is_binary(project.local_path) and copy.root == project.local_path do
      scope = %{
        scope
        | active_project: project,
          active_project_id: project.id,
          active_working_copy_id: copy.id,
          cwd: copy.root
      }

      with {:ok, agent} <-
             CodeMySpec.Agents.start_agent(scope, %{
               role: :main,
               engine: :alloy,
               provider: "claude-code",
               working_copy_id: copy.id,
               working_copy: copy.root
             }),
           {:ok, agent, _} <- CodeMySpec.Agents.set_agent_continuous(scope, agent.id, true) do
        json(conn, %{
          agent_id: agent.id,
          working_copy_id: copy.id,
          status: agent.status,
          continuous: agent.continuous
        })
      else
        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    else
      _ -> refuse(conn)
    end
  end

  def inspect_fixture(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, _project} <- Projects.get_project(scope, params["project_id"]),
         {:ok, snapshot} <- QaFixture.snapshot(params["project_id"]) do
      json(conn, snapshot)
    else
      _ -> refuse(conn)
    end
  end

  def control(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, _project} <- Projects.get_project(scope, params["project_id"]),
         :ok <-
           QaFixture.control(
             params["project_id"],
             params["step"],
             params["action"],
             params["environment"]
           ),
         {:ok, snapshot} <- QaFixture.snapshot(params["project_id"]) do
      json(conn, snapshot)
    else
      _ -> refuse(conn)
    end
  end

  defp authenticate(%{"email" => email, "password" => password})
       when is_binary(email) and is_binary(password) do
    case Users.get_user_by_email_and_password(email, password) do
      nil ->
        {:error, :unauthorized}

      user ->
        case UserPreferences.scope_for(user) do
          %{active_account_id: id} = scope when is_binary(id) -> {:ok, scope}
          _ -> {:error, :select_account_first}
        end
    end
  end

  defp authenticate(_), do: {:error, :unauthorized}

  @doc """
  Agents for QA to act as against this app's own checkout.

  A copy's app has its own database and no harness, so its tools know no
  project, copy or agent and every call answers "no working copy". This
  records the checkout this app runs in as a project and working copy, with a
  local environment so analysis runs here, and a terminal agent per role in
  `roles`. Each agent's headers address `/mcp/harness` as that agent, bearer
  token included: `/mcp/harness` refuses a call without one, and a copy's
  cloned database holds only the seed user's expired tokens.

  With `attachment_fixtures: true` it also answers `attachment_fixtures`, for
  Main's attachment tools: two copies on devices of their own, each with the
  command that starts a harness for it (`online`); a copy on another device
  that no harness answers for (`offline`); and the id of a copy in another
  project (`unauthorized_working_copy_id`).
  """
  def qa_agents(conn, params) do
    root = File.cwd!()
    roles = List.wrap(params["roles"] || ["coding", "coding"])

    with {:ok, scope} <- authenticate(params),
         {:ok, scope} <- qa_copy(scope, root),
         {:ok, agents} <- qa_terminals(scope, roles),
         {:ok, token} <- qa_token(scope),
         {:ok, fixtures} <-
           attachment_fixtures(scope, origin(conn), params["attachment_fixtures"] == true) do
      json(
        conn,
        %{
          project_id: scope.active_project_id,
          working_copy_id: scope.active_working_copy_id,
          root: root,
          agents:
            Enum.map(agents, fn agent ->
              %{
                agent_id: agent.id,
                role: agent.role,
                headers: %{
                  "Authorization" => "Bearer " <> token.token,
                  "X-Project-ID" => scope.active_project_id,
                  "X-Agent-Id" => agent.id
                }
              }
            end)
        }
        |> Map.merge(fixtures)
      )
    else
      {:error, reason} when reason not in [:unauthorized, :select_account_first] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

      _ ->
        refuse(conn)
    end
  end

  defp attachment_fixtures(_scope, _origin, false), do: {:ok, %{}}

  defp attachment_fixtures(scope, origin, true) do
    with {:ok, online_a} <- fixture_copy(scope, "device-a"),
         {:ok, online_b} <- fixture_copy(scope, "device-b"),
         {:ok, offline} <- fixture_copy(scope, "offline"),
         {:ok, elsewhere} <- elsewhere_project(scope),
         {:ok, unauthorized} <- fixture_copy(elsewhere, "unauthorized") do
      {:ok,
       %{
         attachment_fixtures: %{
           online: Enum.map([online_a, online_b], &with_harness(&1, origin)),
           offline: offline,
           unauthorized_working_copy_id: unauthorized.working_copy_id
         }
       }}
    end
  end

  # A copy on a device of its own, with a reported root, an identity file and
  # the device's id where a harness serving it reads it. Offline until a
  # harness is started on it.
  defp fixture_copy(scope, name) do
    # The parent is the device: a harness serving `root` keeps its state there,
    # its key socket included, so short (a Unix socket path is at most 104
    # bytes on macOS, and its temp dir alone is 49).
    root =
      Path.join([
        fixture_base(),
        "cmsqa-#{String.slice(scope.active_project_id, 0, 8)}",
        name,
        "copy"
      ])

    device_name = "qa-#{name}-#{Ecto.UUID.generate()}"

    with :ok <- File.mkdir_p(Path.join(root, "lib")),
         :ok <- File.write(Path.join([root, "lib", "fixture.ex"]), "defmodule Fixture do\nend\n"),
         {:ok, device} <- Devices.announce(scope, nil, %{hostname: device_name, kind: :local}),
         :ok <- write_json(Path.join(Path.dirname(root), "device.json"), %{device_id: device.id}),
         {:ok, copy} <-
           WorkingCopies.issue(scope, nil, device: device.id, root: root, label: name),
         {:ok, copy} <- WorkingCopies.report_root(copy, root),
         {:ok, project} <- Projects.ensure_deploy_key(scope, scope.active_project),
         :ok <- write_identity(root, copy, project),
         :ok <- onboard(root, copy, project) do
      {:ok, %{working_copy_id: copy.id, device_id: device.id, root: root}}
    end
  end

  # Onboarded as `mix cms.harness.onboard` onboards: the settings and harness
  # config `Onboarding.check/2` asks for. No server URL: that would ask this
  # app for a real preview tunnel, and the harness is given the URL by its
  # command.
  defp onboard(root, copy, project) do
    report =
      Onboarding.onboard(root,
        app: "fixture",
        harness_id: copy.id,
        deploy_key: project.deploy_key
      )

    case report.settings do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, {:onboarding_failed, reason}}
    end
  end

  # How to bring the copy online: a harness from this checkout on its port,
  # against this app. QA starts it and stops it by its pid.
  defp with_harness(copy, origin) do
    port = free_port()

    command =
      "CMS_HARNESS=1 CMS_HARNESS_PORT=#{port} CMS_SERVER_URL=#{origin} " <>
        "CMS_PROJECT_DIR=#{copy.root} CMS_ANALYSIS_SLOTS=1 MIX_ENV=harness " <>
        "MIX_BUILD_PATH=_build/qa_harness elixir -S mix run --no-halt"

    Map.put(copy, :harness, %{
      port: port,
      cwd: File.cwd!(),
      command: command,
      ready: "http://127.0.0.1:#{port}/health"
    })
  end

  defp origin(conn),
    do: URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp fixture_base do
    case :os.type() do
      {:win32, _} -> System.tmp_dir!()
      _ -> "/tmp"
    end
  end

  # With the project's deploy key: a harness started on it has no other
  # credential for this app.
  defp write_identity(root, copy, project) do
    write_json(Path.join(root, ".cms_harness.json"), %{
      working_copy_id: copy.id,
      harness_id: copy.id,
      project_id: project.id,
      root: root,
      deploy_key: project.deploy_key
    })
  end

  defp write_json(path, body), do: File.write(path, Jason.encode!(body, pretty: true) <> "\n")

  defp elsewhere_project(scope) do
    with {:ok, project} <-
           Projects.create_project(scope, %{
             name: "QA elsewhere #{Ecto.UUID.generate()}",
             module_name: "QaElsewhere"
           }) do
      {:ok, %{scope | active_project: project, active_project_id: project.id}}
    end
  end

  # Long enough for a QA session; nothing refreshes it.
  @qa_token_seconds 12 * 60 * 60

  defp qa_token(scope),
    do:
      AccessTokens.create_token(scope.user, %{expires_in: @qa_token_seconds},
        otp_app: :code_my_spec
      )

  defp qa_copy(scope, root) do
    with {:ok, project} <- qa_project(scope, root),
         scope = %{scope | active_project: project, active_project_id: project.id},
         {:ok, device} <-
           Devices.announce(scope, nil, %{hostname: "qa-#{project.id}", kind: :local}),
         {:ok, copy} <-
           WorkingCopies.issue(scope, nil,
             device: device.id,
             root: root,
             label: QaEnvironments.label()
           ),
         {:ok, copy} <- WorkingCopies.report_root(copy, root) do
      with :ok <- register_local(copy.id, root),
           do: {:ok, %{scope | active_working_copy_id: copy.id, cwd: root}}
    end
  end

  # Registered from the long-lived owner a copy's app starts, so the entry
  # outlives this request. Main's app has none: it runs no analysis itself.
  defp register_local(copy_id, root) do
    case Process.whereis(QaEnvironments) do
      nil -> {:error, :not_a_copy_app}
      _owner -> QaEnvironments.register(copy_id, root)
    end
  end

  defp qa_project(scope, root) do
    case Projects.get_project_by_local_path(root) do
      {:ok, %{account_id: account_id} = project} when account_id == scope.active_account_id ->
        {:ok, project}

      _ ->
        Projects.create_project(scope, %{
          name: "QA #{Path.basename(root)}",
          module_name: "CodeMySpec",
          local_path: root
        })
    end
  end

  defp qa_terminals(scope, roles) do
    Enum.reduce_while(roles, {:ok, []}, fn role, {:ok, agents} ->
      case Agents.register_terminal(
             scope,
             "qa-#{Ecto.UUID.generate()}",
             String.to_existing_atom(role)
           ) do
        {:ok, agent} -> {:cont, {:ok, agents ++ [agent]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp refuse(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error:
        "Use valid credentials, select an account, and address a registered fixture with a valid control."
    })
  end
end
