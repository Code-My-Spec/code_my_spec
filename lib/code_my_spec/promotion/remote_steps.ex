defmodule CodeMySpec.Promotion.RemoteSteps do
  @moduledoc """
  Git-origin promotion operations. Publication atomically advances the branch
  and writes an immutable receipt for the certified promotion. A retry can
  reconcile a lost response only when that receipt exists. No operation edits
  the source checkout; synchronization is explicitly a destination operation.
  """
  require Logger
  alias CodeMySpec.ExecutionContexts

  @push_attempts 3

  def remote_head(env, root, branch) do
    with :ok <- valid_branch(env, root, branch),
         {:ok, head} <- remote_ref(env, root, "refs/heads/#{branch}"),
         :ok <- valid_sha(head),
         {:ok, _} <-
           remote_command(env, root, [
             "fetch",
             "--no-tags",
             "--no-write-fetch-head",
             "origin",
             head
           ]),
         {:ok, ^head} <- command(env, root, ["rev-parse", "#{head}^{commit}"]) do
      {:ok, %{head: head}}
    end
  end

  @doc "Read the receipt without publishing; an unrelated remote candidate is not a receipt."
  def publication_status(env, root, branch, base, head, promotion_id) do
    with :ok <- valid_branch(env, root, branch),
         :ok <- valid_sha(base),
         :ok <- valid_sha(head),
         {:ok, receipt} <- receipt_ref(promotion_id),
         {:ok, recorded} <- remote_ref(env, root, receipt) do
      case recorded do
        nil ->
          {:ok, %{published: false}}

        ^head ->
          reconcile_receipt(env, root, branch, base, head)

        _ ->
          failure(:rejected, "promotion receipt identifies another candidate")
      end
    end
  end

  defp reconcile_receipt(env, root, branch, base, head) do
    with {:ok, %{head: remote}} <- remote_head(env, root, branch) do
      reconcile(env, root, branch, base, head, remote)
    end
  end

  def publish(env, root, branch, base, head, promotion_id) do
    with :ok <- valid_branch(env, root, branch),
         :ok <- valid_sha(base),
         :ok <- valid_sha(head),
         {:ok, receipt} <- receipt_ref(promotion_id),
         :ok <- ancestor(env, root, base, head),
         {:ok, %{head: remote}} <- remote_head(env, root, branch),
         {:ok, recorded} <- remote_ref(env, root, receipt) do
      case {recorded, remote} do
        {^head, _} ->
          reconcile(env, root, branch, base, head, remote)

        {recorded, _} when not is_nil(recorded) ->
          failure(:rejected, "promotion receipt already identifies another candidate")

        {nil, remote} when remote != base ->
          failure(:moved, "origin/#{branch} moved from #{base} to #{remote}")

        {nil, ^base} ->
          push(env, root, branch, base, head, receipt)
      end
    end
  end

  defp push(env, root, branch, base, head, receipt),
    do: push(env, root, branch, base, head, receipt, 1)

  defp push(env, root, branch, base, head, receipt, attempt) do
    # An exact lease is compare-and-swap, not permission to rewrite history:
    # publish/6 proves base is an ancestor before this command can run.
    result =
      command(env, root, [
        "push",
        "--atomic",
        "--porcelain",
        "--force-with-lease=refs/heads/#{branch}:#{base}",
        "--force-with-lease=#{receipt}:",
        "origin",
        "#{head}:refs/heads/#{branch}",
        "#{head}:#{receipt}"
      ])

    case result do
      {:ok, _} ->
        success(branch, base, head, false)

      {:error, push_error} ->
        case reconcile_push(env, root, branch, base, head, receipt, push_error) do
          {:error, %{retryable: true}} when attempt < @push_attempts ->
            Logger.warning(
              "[Promotion] remote push of #{head} failed on attempt #{attempt}; retrying: #{push_error.reason}"
            )

            Process.sleep(100 * attempt)
            push(env, root, branch, base, head, receipt, attempt + 1)

          {:error, %{retryable: true}} = retry ->
            Logger.warning(
              "[Promotion] remote push of #{head} remains retryable after #{attempt} attempts: #{push_error.reason}"
            )

            retry

          other ->
            other
        end
    end
  end

  defp reconcile_push(env, root, branch, base, head, receipt, push_error) do
    with {:ok, %{head: remote}} <- remote_head(env, root, branch),
         {:ok, recorded} <- remote_ref(env, root, receipt) do
      case {recorded, remote} do
        {^head, _} ->
          reconcile(env, root, branch, base, head, remote)

        {recorded, _} when not is_nil(recorded) ->
          failure(:rejected, "promotion receipt identifies another candidate")

        {nil, remote} when remote != base ->
          failure(:moved, "origin/#{branch} moved without this promotion's receipt")

        {nil, ^base} ->
          if transient_push_error?(push_error.reason),
            do:
              failure(
                :uncertain,
                "remote push failed; retry the same promotion: #{push_error.reason}"
              ),
            else: failure(:rejected, push_error.reason)
      end
    else
      _ ->
        failure(
          :uncertain,
          "push result could not be reconciled; retry the same promotion: #{push_error.reason}"
        )
    end
  end

  defp transient_push_error?(reason) do
    String.match?(
      reason,
      ~r/fatal error in commit_refs|could not resolve host|connection (?:timed out|reset|refused)|remote end hung up|the requested URL returned error: 5\d\d/i
    )
  end

  defp reconcile(env, root, branch, base, head, remote) do
    case ancestor(env, root, head, remote) do
      :ok ->
        success(branch, base, head, true)

      _ ->
        failure(
          :uncertain,
          "promotion receipt exists but the destination no longer contains its candidate"
        )
    end
  end

  def sync_remote(env, root, branch, head) do
    with :ok <- valid_branch(env, root, branch),
         :ok <- valid_sha(head),
         {:ok, ^branch} <- command(env, root, ["symbolic-ref", "--short", "HEAD"]),
         :ok <- clean(env, root),
         {:ok, %{head: remote}} <- remote_head(env, root, branch),
         :ok <- ancestor(env, root, head, remote),
         {:ok, before} <- command(env, root, ["rev-parse", "HEAD"]),
         :ok <- ancestor(env, root, before, head),
         {:ok, changed} <- command(env, root, ["diff", "--name-only", before, head]),
         {:ok, _} <-
           command(env, root, ["-c", "submodule.recurse=false", "merge", "--ff-only", head]),
         {:ok, _} <- command(env, root, ["submodule", "sync", "--recursive"]),
         {:ok, _} <- command(env, root, ["submodule", "update", "--init", "--recursive"]),
         {:ok, ^head} <- command(env, root, ["rev-parse", "HEAD"]),
         :ok <- clean(env, root) do
      {:ok,
       %{
         head: head,
         before: before,
         after: head,
         branch: branch,
         synced: true,
         changed_files: String.split(changed, "\n", trim: true)
       }}
    else
      {:ok, other} ->
        failure(:rejected, "destination is on an unexpected branch or revision: #{other}")

      error ->
        error
    end
  end

  defp clean(env, root) do
    case command(env, root, [
           "status",
           "--porcelain",
           "--untracked-files=all",
           "--ignore-submodules=none"
         ]) do
      {:ok, ""} -> :ok
      {:ok, _} -> failure(:dirty, "destination has uncommitted work; refusing synchronization")
      error -> error
    end
  end

  defp ancestor(env, root, base, head) do
    case command(env, root, ["merge-base", "--is-ancestor", base, head]) do
      {:ok, _} -> :ok
      _ -> failure(:rejected, "#{head} is not a proven fast-forward of #{base}")
    end
  end

  defp valid_branch(env, root, branch) when is_binary(branch) do
    case command(env, root, ["check-ref-format", "refs/heads/#{branch}"]) do
      {:ok, _} -> :ok
      _ -> failure(:rejected, "invalid destination branch")
    end
  end

  defp valid_branch(_, _, _), do: failure(:rejected, "destination branch is required")

  defp valid_sha(sha) when is_binary(sha) do
    case Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, sha) do
      true -> :ok
      false -> failure(:rejected, "an exact commit SHA is required")
    end
  end

  defp valid_sha(_), do: failure(:rejected, "an exact commit SHA is required")

  defp receipt_ref(id) when is_binary(id) do
    case Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id) do
      true -> {:ok, "refs/codemyspec/promotions/#{id}"}
      false -> failure(:rejected, "invalid promotion identity")
    end
  end

  defp receipt_ref(_), do: failure(:rejected, "promotion identity is required")

  defp remote_ref(env, root, ref) do
    case remote_command(env, root, ["ls-remote", "--refs", "origin", ref]) do
      {:ok, ""} -> {:ok, nil}
      {:ok, line} -> {:ok, line |> String.split() |> hd()}
      error -> error
    end
  end

  defp success(branch, base, head, reconciled),
    do:
      {:ok,
       %{
         head: head,
         branch: branch,
         base: base,
         published: true,
         reconciled: reconciled,
         version: head,
         stamp_version: head
       }}

  defp failure(:moved, reason), do: {:error, %{status: :moved, base_moved: true, reason: reason}}

  defp failure(:uncertain, reason),
    do: {:error, %{status: :uncertain, retryable: true, uncertain: true, reason: reason}}

  defp failure(status, reason), do: {:error, %{status: status, reason: reason}}

  defp remote_command(env, root, args) do
    case command(env, root, args) do
      {:ok, _} = ok -> ok
      {:error, error} -> failure(:uncertain, error.reason)
    end
  end

  defp command(env, root, args) do
    case ExecutionContexts.cmd(env, "git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} when is_binary(output) ->
        failure(:rejected, "git failed (#{status}): #{String.trim(output)}")

      other ->
        failure(:uncertain, "git could not complete: #{inspect(other)}")
    end
  end
end
