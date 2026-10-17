defmodule CodeMySpec.Uploads do
  @moduledoc """
  S3 upload helpers for presigned URLs.
  """

  use Boundary, top_level?: true, deps: []

  def presigned_upload_url(key, content_type, opts \\ []) do
    bucket = bucket()
    expires_in = Keyword.get(opts, :expires_in, 300)

    ExAws.S3.presigned_url(ExAws.Config.new(:s3), :put, bucket, key,
      expires_in: expires_in,
      headers: [{"content-type", content_type}]
    )
  end

  def presigned_download_url(key, opts \\ []) do
    bucket = bucket()
    expires_in = Keyword.get(opts, :expires_in, 3600)

    ExAws.S3.presigned_url(ExAws.Config.new(:s3), :get, bucket, key, expires_in: expires_in)
  end

  def generate_key(project_id, filename) do
    "issues/#{project_id}/#{Ecto.UUID.generate()}/#{filename}"
  end

  @doc """
  PUT `body` to a presigned URL from `presigned_upload_url/3` — the half of
  that split every existing caller leaves to a browser, performed here for a
  caller with no browser to do it (`CodeMySpec.Qa.EvidenceUpload`). Flows
  through `Req` so specs intercept it with a `plug: {Req.Test, __MODULE__}`
  the same way `CodeMySpec.Content.ExAwsReqClient` lets specs intercept S3
  traffic.
  """
  @spec upload(String.t(), iodata(), String.t()) :: :ok | {:error, term()}
  def upload(url, body, content_type) do
    opts =
      [
        method: :put,
        url: url,
        body: body,
        headers: [{"content-type", content_type}],
        decode_body: false,
        retry: false
      ]
      |> maybe_plug()

    case Req.request(opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether an S3 bucket is configured — false in local dev with no bucket set."
  @spec configured? :: boolean()
  def configured? do
    match?({:ok, _}, Application.fetch_env(:code_my_spec, :s3_bucket))
  end

  defp maybe_plug(opts) do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp bucket do
    Application.fetch_env!(:code_my_spec, :s3_bucket)
  end
end
