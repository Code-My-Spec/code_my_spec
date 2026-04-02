defmodule CodeMySpec.Uploads do
  @moduledoc """
  S3 upload helpers for presigned URLs.
  """

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

    ExAws.S3.presigned_url(ExAws.Config.new(:s3), :get, bucket, key,
      expires_in: expires_in
    )
  end

  def generate_key(project_id, filename) do
    "issues/#{project_id}/#{Ecto.UUID.generate()}/#{filename}"
  end

  def delete_object(key) do
    ExAws.S3.delete_object(bucket(), key) |> ExAws.request()
  end

  defp bucket do
    Application.fetch_env!(:code_my_spec, :s3_bucket)
  end
end
