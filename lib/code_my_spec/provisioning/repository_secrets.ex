defmodule CodeMySpec.Provisioning.RepositorySecrets do
  @moduledoc "Writes encrypted environment secrets straight to the project's GitHub repository."

  alias CodeMySpec.GitHub
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sops, Steps}
  alias CodeMySpec.Users.Scope

  @spec put(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def put(scope, environment, key, value)
      when is_binary(environment) and is_binary(key) and is_binary(value) do
    with {:ok, result} <- put_many(scope, environment, [{key, value}]) do
      {:ok, Map.put(result, :key, key)}
    end
  end

  def put(_scope, _environment, _key, _value),
    do: {:error, "Project repository is not configured."}

  @doc """
  Set every `{key, value}` in one commit: the file is re-encrypted once per
  key in memory and written once.
  """
  @spec put_many(Scope.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, map()} | {:error, String.t()}
  def put_many(%Scope{active_project: %{code_repo: repo} = project} = scope, environment, pairs)
      when is_binary(environment) and is_list(pairs) and pairs != [] do
    with :ok <- validate_all(environment, pairs, repo),
         {:ok, owner, name} <- location(repo),
         {:ok, private} <- private_key(scope, environment),
         branch = project.development_branch || "main",
         {:ok, %{content: config}} <- GitHub.get_file(scope, owner, name, ".sops.yaml", branch) do
      write(
        %{
          scope: scope,
          owner: owner,
          name: name,
          branch: branch,
          config: config,
          environment: environment,
          pairs: pairs,
          private: private
        },
        1
      )
    else
      {:error, :github_not_connected} ->
        {:error, "Reconnect GitHub before writing secrets."}

      {:error, :not_found} ->
        {:error, "The repository has no .sops.yaml. Run secrets setup first."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "Could not read the repository secrets configuration."}
    end
  end

  def put_many(_scope, _environment, []), do: {:error, "No secrets to write."}

  def put_many(_scope, _environment, _pairs),
    do: {:error, "Project repository is not configured."}

  defp write(ctx, retries) do
    path = Sops.env_file(ctx.environment)

    with {:ok, existing} <- current_file(ctx.scope, ctx.owner, ctx.name, path, ctx.branch),
         {:ok, ciphertext} <- encrypt_all(ctx, existing.content) do
      case GitHub.put_file(
             ctx.scope,
             ctx.owner,
             ctx.name,
             path,
             ctx.branch,
             ciphertext,
             commit_message(ctx),
             existing.sha
           ) do
        {:ok, commit} ->
          {:ok,
           %{
             environment: ctx.environment,
             keys: Enum.map(ctx.pairs, &elem(&1, 0)),
             file: path,
             commit: commit
           }}

        {:error, :stale_file} when retries > 0 ->
          write(ctx, retries - 1)

        {:error, :stale_file} ->
          {:error, "The secrets file changed concurrently. Try again."}

        {:error, _} ->
          {:error, "Could not commit the encrypted secrets file."}
      end
    else
      {:error, :github_not_connected} -> {:error, "Reconnect GitHub before writing secrets."}
      {:error, :invalid_file_content} -> {:error, "The repository secrets file is invalid."}
      {:error, _} -> {:error, "Could not update the encrypted secrets file."}
    end
  end

  defp encrypt_all(ctx, content) do
    Enum.reduce_while(ctx.pairs, {:ok, content}, fn {key, value}, {:ok, current} ->
      ctx.config
      |> Sops.set_repository_file(current, ctx.environment, key, value, ctx.private)
      |> case do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp commit_message(%{pairs: [{key, _}], environment: environment}),
    do: "Set #{key} in #{environment} secrets"

  defp commit_message(%{pairs: pairs, environment: environment}),
    do: "Set #{length(pairs)} secrets in #{environment}"

  defp current_file(scope, owner, name, path, branch) do
    case GitHub.get_file(scope, owner, name, path, branch) do
      {:ok, file} -> {:ok, file}
      {:error, :not_found} -> {:ok, %{content: nil, sha: nil}}
      other -> other
    end
  end

  defp private_key(scope, environment) do
    case ProjectSecrets.fetch_value(scope, Steps.age_key_name(environment)) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "The #{environment} age key is missing. Run secrets setup first."}
    end
  end

  defp validate_all(environment, pairs, repo) do
    Enum.find_value(pairs, :ok, fn {key, _value} ->
      case validate(environment, key, repo) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp validate(environment, key, repo) do
    cond do
      not is_binary(repo) or repo == "" -> {:error, "Project repository is not configured."}
      not Regex.match?(~r/\A[a-z0-9_-]+\z/, environment) -> {:error, "Invalid environment."}
      not Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) -> {:error, "Invalid secret name."}
      true -> :ok
    end
  end

  defp location(repo) do
    case URI.parse(repo) do
      %URI{host: "github.com", path: path} when is_binary(path) ->
        case path |> String.trim_trailing(".git") |> String.split("/", trim: true) do
          [owner, name] -> {:ok, owner, name}
          _ -> {:error, "Project repository is not a GitHub repository."}
        end

      _ ->
        {:error, "Project repository is not a GitHub repository."}
    end
  end
end
