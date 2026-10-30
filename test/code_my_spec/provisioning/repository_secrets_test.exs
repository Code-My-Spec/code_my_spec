defmodule CodeMySpec.Provisioning.RepositorySecretsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
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

  test "refuses a missing key before reading or committing secrets and names the recorded server",
       ctx do
    {:ok, _} = Environments.put(ctx.scope, "prod", %{server_name: "prod-box"})
    {:ok, _} = ProjectSecrets.delete_value(ctx.scope, Steps.age_key_name("prod"))

    assert {:error, message} =
             RepositorySecrets.put(ctx.scope, "prod", "TOKEN", "sensitive-value")

    assert message ==
             "This server has no key for prod's secrets; they were set up on prod-box. Put secrets there."

    refute message =~ "sensitive-value"
    assert %{puts: 0, file: nil} = Agent.get(ctx.state, & &1)
  end

  test "refuses a key whose public recipient differs from .sops.yaml", ctx do
    {:ok, {_public, other_private}} = Sops.generate_key()
    {:ok, _} = ProjectSecrets.put_value(ctx.scope, Steps.age_key_name("prod"), other_private)
    {:ok, _} = Environments.put(ctx.scope, "prod", %{server_name: "prod-box"})

    assert {:error, message} =
             RepositorySecrets.put(ctx.scope, "prod", "TOKEN", "sensitive-value")

    assert message =~ "they were set up on prod-box. Put secrets there."
    refute message =~ "sensitive-value"
    refute message =~ "sops_failed"
    assert %{puts: 0, file: nil} = Agent.get(ctx.state, & &1)
  end

  test "bulk import refuses a mismatched key without a commit", ctx do
    {:ok, {_public, other_private}} = Sops.generate_key()
    {:ok, _} = ProjectSecrets.put_value(ctx.scope, Steps.age_key_name("prod"), other_private)

    assert {:error, message} =
             Steps.import_dotenv_in_repository(ctx.scope, "prod", "FIRST=one\nSECOND=two\n")

    assert message =~ "This server has no key for prod's secrets"
    refute message =~ "sops_failed"
    assert %{puts: 0, file: nil} = Agent.get(ctx.state, & &1)
  end

  test "does not guess the origin server when it was never recorded", ctx do
    {:ok, _} = ProjectSecrets.delete_value(ctx.scope, Steps.age_key_name("prod"))

    assert {:error, message} =
             RepositorySecrets.put(ctx.scope, "prod", "TOKEN", "sensitive-value")

    assert message =~ "server where they were set up is not recorded"
    refute message =~ "sensitive-value"
    assert %{puts: 0, file: nil} = Agent.get(ctx.state, & &1)
  end

  test "writes many secrets in one commit, none of them in the response", ctx do
    pairs = [{"GITHUB_CLIENT_ID", "id-value"}, {"GITHUB_CLIENT_SECRET", "secret-value"}]

    assert {:ok, result} = RepositorySecrets.put_many(ctx.scope, "prod", pairs)
    assert result.keys == ["GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET"]
    refute inspect(result) =~ "secret-value"

    %{file: ciphertext, puts: 1} = Agent.get(ctx.state, & &1)
    assert {:ok, values} = decrypt_content(ctx.config, ciphertext, ctx.private)
    assert values["GITHUB_CLIENT_ID"] == "id-value"
    assert values["GITHUB_CLIENT_SECRET"] == "secret-value"
  end

  test "a pasted env file imports through the repository with no working copy", ctx do
    dotenv = "# app secrets\nRESEND_API_KEY=re-value\n\nGA4_MEASUREMENT_ID=G-123\n"

    assert {:ok, ["GA4_MEASUREMENT_ID", "RESEND_API_KEY"]} =
             Steps.import_dotenv_in_repository(ctx.scope, "prod", dotenv)

    %{file: ciphertext, puts: 1} = Agent.get(ctx.state, & &1)
    assert {:ok, values} = decrypt_content(ctx.config, ciphertext, ctx.private)
    assert values["RESEND_API_KEY"] == "re-value"
    assert values["GA4_MEASUREMENT_ID"] == "G-123"
  end

  test "an invalid name refuses the whole batch before anything is written", ctx do
    assert {:error, "Invalid secret name."} =
             RepositorySecrets.put_many(ctx.scope, "prod", [{"OK_KEY", "a"}, {"bad-key", "b"}])

    assert %{puts: 0} = Agent.get(ctx.state, & &1)
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
    github_get_reply(conn, Agent.get(state, & &1), String.contains?(path, ".sops.yaml"))
  end

  defp github_reply(%{method: "PUT"} = conn, state) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)
    outcome = Agent.get_and_update(state, &put_outcome(&1, payload))
    put_reply(conn, outcome, state)
  end

  defp github_get_reply(conn, data, true), do: file_reply(conn, data.config, "config-sha")
  defp github_get_reply(conn, %{file: nil}, false), do: json(conn, 404, %{})
  defp github_get_reply(conn, data, false), do: file_reply(conn, data.file, data.sha)

  defp put_outcome(%{stale_once: true} = data, _payload) do
    next = %{data | puts: data.puts + 1, stale_once: false, sha: "stale-sha"}
    {:stale, next}
  end

  defp put_outcome(data, payload) do
    put_outcome_for_sha(data, payload, Map.get(payload, "sha"), data.sha)
  end

  defp put_outcome_for_sha(data, payload, sha, sha) do
    puts = data.puts + 1
    next = %{data | puts: puts, file: Base.decode64!(payload["content"]), sha: "blob-#{puts}"}
    {:ok, next}
  end

  defp put_outcome_for_sha(data, _payload, _sent, _current),
    do: {:stale, %{data | puts: data.puts + 1}}

  defp put_reply(conn, :stale, _state), do: json(conn, 409, %{})

  defp put_reply(conn, :ok, state),
    do: json(conn, 200, %{"commit" => %{"sha" => "commit-#{Agent.get(state, & &1.puts)}"}})

  defp file_reply(conn, content, sha),
    do: json(conn, 200, %{"type" => "file", "content" => Base.encode64(content), "sha" => sha})

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
