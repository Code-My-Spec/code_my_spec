defmodule CodeMySpec.Provisioning.ContentPublishing do
  @moduledoc """
  Wires the already-built publish pipeline onto the newly provisioned stack.

  The pipeline itself is `CodeMySpec.ContentPublishing` (story 712): snapshot →
  content blob + manifest into the project's bucket → pull trigger to the
  deployed client. This module does not reimplement any of that. It owns the
  provisioning half — is the bucket there, is the trigger configured — and the
  proof that the whole thing works end to end.

  ## Why the trigger config is checked before publishing, not after

  Sync is trigger-only. There is no reconciliation pass, no eventual retry, no
  background sweep that notices the site is stale. If the trigger does not
  land, the content sits in the bucket forever and the site never learns about
  it.

  That makes an unconfigured trigger indistinguishable from a working publish
  unless someone checks. `ensure_publishable/1` refuses to start when
  `client_api_url` or `deploy_key` is missing, so the silent case cannot be
  reached from the provisioning path (criterion 8058).

  The pipeline agrees now. `ContentPublishing.trigger_client/2` used to have a
  fallback clause returning `{:ok, %{sync_id: nil}}` for exactly that
  unconfigured project — reporting success for a publish nothing was told
  about — and this note used to warn about it. That clause now returns an
  error naming the missing fields, and `ContentLive` surfaces it as a flash
  rather than a silent success, so the guard here is defence in depth rather
  than the only thing standing between an operator and a lie.

  ## Done means rendered, not uploaded

  `run/2` is not finished when the objects land or when the trigger returns —
  it is finished when a real post has been fetched back from the deployed site
  over HTTP with its content in the body (criteria 8036, 8039). A publish that
  uploads and triggers but renders nothing is a failure that looks like a
  success everywhere except the site itself.

  `verify_render/3` therefore checks both the status AND that the body
  actually contains the expected content. A 200 alone would pass on a
  catch-all route or a styled 404.
  """

  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  @type result :: %{
          state: :rendered | :trigger_failed | :publish_failed | :not_rendered,
          published: map() | nil,
          render: map() | nil,
          proven_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @doc """
  Whether the project carries everything the trigger-only pipeline needs.

  Returns `:ok` or `{:error, {:not_publishable, missing}}` naming the missing
  fields, because "publishing is not configured" is not something a user can
  act on but "client_api_url is missing" is.
  """
  @spec ensure_publishable(Scope.t()) :: :ok | {:error, {:not_publishable, [atom()]}}
  def ensure_publishable(%Scope{active_project: project}) when not is_nil(project) do
    missing =
      [:content_bucket, :client_api_url, :deploy_key]
      |> Enum.filter(fn field -> blank?(Map.get(project, field)) end)

    case missing do
      [] -> :ok
      missing -> {:error, {:not_publishable, missing}}
    end
  end

  def ensure_publishable(%Scope{}), do: {:error, {:not_publishable, [:active_project]}}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc """
  Publish, then prove the post rendered on the live site.

  `opts`:
    * `:path` — the path to fetch back (e.g. `"/blog/hello-world"`), required
    * `:expect` — a string that must appear in the rendered body, required
    * `:publish` / `:fetch` — injection points for tests
    * `:now` — clock injection
  """
  @spec run(Scope.t(), keyword()) :: result()
  def run(%Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    publish = Keyword.get(opts, :publish, &CodeMySpec.ContentPublishing.publish/1)
    sync = Keyword.get(opts, :sync, &CodeMySpec.ContentPublishing.sync/1)

    # `verify_render/2` is handled in a `case` rather than as another `with`
    # clause so `published` is still in scope when it fails. As an `else`
    # branch it was not, and the not-rendered result reported `published: nil`
    # — throwing away the fact that the objects had landed. That is exactly the
    # distinction criterion 8058 turns on: files uploaded but the post not
    # served is a different failure from a publish that never happened, and it
    # was unanswerable one layer above.
    with :ok <- ensure_publishable(scope),
         :ok <- snapshot(sync, scope),
         {:ok, published} <- publish.(scope) do
      case await_render(published, opts) do
        {:ok, render} ->
          %{
            state: :rendered,
            published: published,
            render: render,
            proven_at: now.(),
            reason: nil
          }

        {:error, {:not_rendered, render}} ->
          %{
            state: :not_rendered,
            published: published,
            render: render,
            proven_at: nil,
            reason: render_failure_reason(render, opts)
          }
      end
    else
      {:error, {:not_publishable, missing}} ->
        failure(
          :trigger_failed,
          "Publishing is not configured — #{Enum.join(missing, ", ")} " <>
            "missing. Sync is trigger-only, so a publish without a reachable client would " <>
            "never reach the site."
        )

      {:error, %{message: message} = err} ->
        # A failed trigger leaves the objects in the bucket, and the publish
        # carries them out with the error now. Reporting `published: nil` here
        # said nothing had been written, so a re-trigger looked like a
        # re-upload — the distinction 8058 exists to make.
        failure(publish_failure_state(message), message, uploaded(err))

      {:error, reason} ->
        failure(:publish_failed, inspect(reason))
    end
  end

  # One command, not a checklist: the post on disk is the post that gets
  # published. `publish/1` reads the snapshot table and nothing here filled it,
  # so a publish uploaded whatever the last sync had left — for a project that
  # had never synced, an empty `content.json` of two bytes, uploaded and
  # triggered and reported as a success with no content in it.
  #
  # A project with no source path configured has its snapshot filled some other
  # way; publishing what is already there is right, and is left alone.
  defp snapshot(sync, scope) do
    case sync.(scope) do
      {:ok, _counts} -> :ok
      {:error, :no_source_path} -> :ok
      {:error, reason} -> {:error, %{message: "Content sync failed: #{inspect(reason)}"}}
    end
  end

  # The pipeline reports a failed trigger through the same {:error, %{message:}}
  # shape as an S3 failure, so the message is what distinguishes them. Getting
  # this wrong would file a lost trigger as a storage problem.
  defp publish_failure_state(message) do
    if message =~ ~r/trigger/i, do: :trigger_failed, else: :publish_failed
  end

  defp failure(state, reason, published \\ nil) do
    %{state: state, published: published, render: nil, proven_at: nil, reason: reason}
  end

  defp uploaded(%{objects: objects}) when objects not in [nil, []], do: %{objects: objects}
  defp uploaded(_err), do: nil

  defp render_failure_reason(%{status: status, body_contains: false}, opts) do
    "The site answered #{status} but the page did not contain " <>
      "#{inspect(Keyword.get(opts, :expect))} — published but not served."
  end

  defp render_failure_reason(%{status: status}, _opts),
    do: "The site answered #{status} for the published path — published but not served."

  # The trigger answers `202 accepted`, which means the site has taken the job
  # and not that it has finished it. Fetching the post once, immediately, is a
  # race the pipeline cannot win — and it loses quietly, reporting `not_rendered`
  # for content that appears a second later. Against the fleet the post is
  # served about eight seconds after the trigger; a single fetch found 404 every
  # time while a hand-run `curl` moments afterwards found 200.
  #
  # Retried rather than slept: a publish to a warm site should still be fast.
  defp await_render(published, opts) do
    attempts = Keyword.get(opts, :render_attempts, 15)
    interval = Keyword.get(opts, :render_interval_ms, 2_000)

    Enum.reduce_while(1..attempts, nil, fn attempt, _acc ->
      case verify_render(published, opts) do
        {:ok, render} ->
          {:halt, {:ok, render}}

        {:error, {:not_rendered, _}} = error when attempt == attempts ->
          {:halt, error}

        {:error, {:not_rendered, _}} = error ->
          Wait.sleep(interval)
          {:cont, error}
      end
    end)
  end

  @doc """
  Fetch a published path back from the live site.

  Checks the status AND the body. A 200 on its own would pass against a
  catch-all route or a styled 404, which is the failure mode criterion 8038
  exists to catch: content that does not verify must be left unserved rather
  than assumed good.
  """
  @spec verify_render(map(), keyword()) :: {:ok, map()} | {:error, {:not_rendered, map()}}
  def verify_render(published, opts) do
    fetch = Keyword.get(opts, :fetch, &fetch/2)
    path = Keyword.fetch!(opts, :path)
    expect = Keyword.fetch!(opts, :expect)
    base = Keyword.get(opts, :site_url) || Map.get(published, :site_url)

    case fetch.(base, path) do
      {:ok, %{status: 200, body: body}} ->
        contains = String.contains?(body, expect)
        render = %{status: 200, path: path, body_contains: contains}

        if contains, do: {:ok, render}, else: {:error, {:not_rendered, render}}

      {:ok, %{status: status}} ->
        {:error, {:not_rendered, %{status: status, path: path, body_contains: false}}}

      {:error, reason} ->
        {:error, {:not_rendered, %{status: inspect(reason), path: path, body_contains: false}}}
    end
  end

  defp fetch(base, path) do
    req_opts =
      [method: :get, url: "#{base}#{path}", retry: false, receive_timeout: 15_000] ++ plug_opt()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
