defmodule CodeMySpec.Issues.ScreenshotStore do
  @moduledoc """
  Copies a widget-reported screenshot (a `data:` URL captured in the browser)
  into our S3 bucket and returns an attachment map to store on the issue.

  The bytes ride the deploy-key socket as a base64 `data:` URL, so we decode
  them server-side and PUT them under the project's `issues/` prefix (the same
  bucket used for issue uploads and mail attachments). The issue keeps only the
  stable `s3_key`; the operator's issue view presigns it on demand.

  Best-effort: a malformed or oversized image yields `:error` and the caller
  files the issue without an attachment rather than failing the report.
  """

  require Logger

  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Uploads

  # Guard against a hostile/huge base64 payload over the socket (~8 MB decoded).
  @max_bytes 8_000_000

  @doc """
  Store a `data:` screenshot for `project_id`. Returns
  `{:ok, attachment_map}` or `:error`.
  """
  @spec store(String.t(), String.t()) :: {:ok, map()} | :error
  def store(project_id, data_url) when is_binary(project_id) and is_binary(data_url) do
    with {:ok, content_type, bytes} <- decode(data_url),
         :ok <- within_size(bytes),
         key = Uploads.generate_key(project_id, filename(content_type)),
         :ok <- S3Client.put_object(bucket(), key, bytes, content_type: content_type) do
      {:ok, %{"type" => "screenshot", "s3_key" => key, "content_type" => content_type}}
    else
      other ->
        Logger.warning("Issues.ScreenshotStore: could not store screenshot: #{inspect(other)}")
        :error
    end
  end

  def store(_project_id, _data_url), do: :error

  # data:image/png;base64,AAAA...
  defp decode("data:" <> rest) do
    with [meta, b64] <- String.split(rest, ",", parts: 2),
         [content_type | _] <- String.split(meta, ";"),
         true <- String.starts_with?(content_type, "image/"),
         {:ok, bytes} <- Base.decode64(b64) do
      {:ok, content_type, bytes}
    else
      _ -> :error
    end
  end

  defp decode(_), do: :error

  defp within_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp within_size(_bytes), do: :error

  defp filename("image/png"), do: "screenshot.png"
  defp filename("image/jpeg"), do: "screenshot.jpg"
  defp filename("image/webp"), do: "screenshot.webp"
  defp filename(_), do: "screenshot.png"

  defp bucket, do: Application.fetch_env!(:code_my_spec, :s3_bucket)
end
