defmodule CodeMySpec.Provisioning.Builder.Version do
  @moduledoc "Resolve the version of the exact commit sent to the builder."

  alias CodeMySpec.ExecutionContexts

  @sha ~r/\A[0-9a-f]{40}\z/
  @ref ~r/\A[0-9a-f]{6,40}\z/
  @release_tag ~r/\Av[0-9]+\.[0-9]+\.[0-9]+\z/
  @unknown "cannot build image: could not determine the commit being built"

  @spec for_ref(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def for_ref(ref, opts) do
    with true <- is_binary(ref) and Regex.match?(@ref, ref),
         {:ok, sha, tags} <- lookup(ref, opts),
         true <- is_binary(sha) and Regex.match?(@sha, sha) and String.starts_with?(sha, ref) do
      version =
        tags
        |> Enum.filter(&Regex.match?(@release_tag, &1))
        |> Enum.sort()
        |> List.last()
        |> case do
          nil -> String.slice(sha, 0, 12)
          tag -> tag
        end

      {:ok, version}
    else
      _ -> {:error, @unknown}
    end
  end

  defp lookup(ref, opts) do
    case Keyword.get(opts, :version_lookup) do
      fun when is_function(fun, 1) -> fun.(ref)
      _ -> source_lookup(ref, opts)
    end
  end

  defp source_lookup(ref, opts) do
    cond do
      is_binary(opts[:version_cd]) ->
        git_lookup(ref, fn args ->
          System.cmd("git", args, cd: opts[:version_cd], stderr_to_stdout: true)
        end)

      is_binary(opts[:github_repo]) and is_binary(opts[:github_token]) ->
        github_lookup(ref, opts)

      match?(%{cwd: cwd} when is_binary(cwd), opts[:env]) ->
        git_lookup(ref, fn args ->
          ExecutionContexts.cmd(opts[:env], "git", args, stderr_to_stdout: true)
        end)

      true ->
        {:error, @unknown}
    end
  end

  defp git_lookup(ref, git) do
    case git.(["rev-parse", "--verify", "#{ref}^{commit}"]) do
      {output, 0} ->
        sha = String.trim(output)

        case git.(["tag", "--points-at", sha]) do
          {tags, 0} -> {:ok, sha, String.split(tags, "\n", trim: true)}
          _ -> {:error, @unknown}
        end

      _ ->
        {:error, @unknown}
    end
  end

  defp github_lookup(ref, opts) do
    base = "https://api.github.com/repos/#{opts[:github_repo]}"
    headers = [{"authorization", "Bearer #{opts[:github_token]}"}]

    request_opts = Application.get_env(:code_my_spec, __MODULE__, [])

    with {:ok, %Req.Response{status: 200, body: %{"sha" => sha}}} <-
           Req.get(base <> "/commits/" <> ref, Keyword.merge(request_opts, headers: headers)),
         {:ok, tags} <- github_tags(base, headers, sha, 1, [], request_opts) do
      {:ok, sha, tags}
    else
      _ -> {:error, @unknown}
    end
  end

  defp github_tags(base, headers, sha, page, found, request_opts) do
    opts = Keyword.merge(request_opts, headers: headers, params: [per_page: 100, page: page])

    case Req.get(base <> "/tags", opts) do
      {:ok, %Req.Response{status: 200, body: []}} ->
        {:ok, found}

      {:ok, %Req.Response{status: 200, body: tags}} when is_list(tags) ->
        matching = for %{"name" => name, "commit" => %{"sha" => ^sha}} <- tags, do: name
        github_tags(base, headers, sha, page + 1, matching ++ found, request_opts)

      _ ->
        {:error, @unknown}
    end
  end
end
