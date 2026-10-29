defmodule CodeMySpec.Provisioning.RepositorySecretsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.GitHub
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{RepositorySecrets, Sops, Steps}

  @moduletag :sops

  setup do
    scope = full_scope_fixture(%{code_repo: "https://github.com/testuser/example.git"})
    github_integration_fixture(scope.user)
    scope = %{scope | active_working_copy_id: nil, cwd: nil}
    {:ok, {public, private}} = Sops.generate_key()
    {:ok, _} = ProjectSecrets.put_value(scope, Steps.age_key_name("prod"), private)
    dir = CodeMySpec.TempFile.owned_dir("repo-secrets-test")
    local = ExecutionContext.new(:local, dir)
    :ok = Sops.write_config(local, %{"prod" => public})
    config = File.read!(Path.join(dir, ".sops.yaml"))

    {:ok, state} =
      Agent.start_link(fn ->
        %{config: config, file: nil, sha: nil, puts: 0, stale_once: false}
      end)

    Req.Test.stub(GitHub, fn conn -> github_reply(conn, state) end)
    %{scope: scope, state: state, config: config, private: private}
  end

  test "creates the first encrypted secret without a working copy or value in the response",
       ctx do
    value = "private-value-for-prod"
    assert {:ok, result} = RepositorySecrets.put(ctx.scope, "prod", "VAPID_KEY", value)
    assert result.commit == "commit-1"
    refute inspect(result) =~ value
    %{file: ciphertext, puts: 1} = Agent.get(ctx.state, & &1)
    assert ciphertext =~ "ENC["
    refute ciphertext =~ value

    assert {:ok, plaintext} =
             decrypt_content(ctx.config, ciphertext, ctx.private)

    assert plaintext["VAPID_KEY"] == value
  end

  test "re-reads a stale blob once before committing the encrypted update", ctx do
    assert {:ok, _} = RepositorySecrets.put(ctx.scope, "prod", "FIRST", "one")
    Agent.update(ctx.state, &%{&1 | stale_once: true})

    assert {:ok, %{commit: "commit-3"}} =
             RepositorySecrets.put(ctx.scope, "prod", "SECOND", "two")

    %{puts: 3, file: ciphertext} = Agent.get(ctx.state, & &1)
    assert {:ok, values} = decrypt_content(ctx.config, ciphertext, ctx.private)
    assert values == %{"SOPS_INITIALIZED" => "true", "FIRST" => "one", "SECOND" => "two"}
  end

  defp decrypt_content(config, ciphertext, private) do
    dir = CodeMySpec.TempFile.owned_dir("repo-secrets-decrypt")
    local = ExecutionContext.new(:local, dir)
    File.mkdir_p!(Path.join(dir, "envs"))
    File.write!(Path.join(dir, ".sops.yaml"), config)
    File.write!(Path.join(dir, Sops.env_file("prod")), ciphertext)
    Sops.decrypt(local, "prod", private)
  end

  defp github_reply(%{method: "GET", request_path: path} = conn, state) do
    data = Agent.get(state, & &1)

    cond do
      String.contains?(path, ".sops.yaml") -> file_reply(conn, data.config, "config-sha")
      data.file == nil -> json(conn, 404, %{})
      true -> file_reply(conn, data.file, data.sha)
    end
  end

  defp github_reply(%{method: "PUT"} = conn, state) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)

    outcome =
      Agent.get_and_update(state, fn data ->
        next = %{data | puts: data.puts + 1}

        cond do
          data.stale_once ->
            {:stale, %{next | stale_once: false, sha: "stale-sha"}}

          payload["sha"] != data.sha ->
            {:stale, next}

          true ->
            {:ok, %{next | file: Base.decode64!(payload["content"]), sha: "blob-#{next.puts}"}}
        end
      end)

    case outcome do
      :stale -> json(conn, 409, %{})
      :ok -> json(conn, 200, %{"commit" => %{"sha" => "commit-#{Agent.get(state, & &1.puts)}"}})
    end
  end

  defp file_reply(conn, content, sha),
    do: json(conn, 200, %{"type" => "file", "content" => Base.encode64(content), "sha" => sha})

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
