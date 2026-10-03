defmodule CodeMySpec.Qa.EvidenceUpload do
  @moduledoc """
  Uploads a QA attempt's screenshot/recording files to object storage via
  presigned PUT, so they can be recorded on the attempt instead of relying
  on a git commit of `.code_my_spec/qa/<story_number>/screenshots/` — the
  gap `CodeMySpec.Qa.Evidence` used to refuse a submission over.

  Best-effort throughout: no S3 bucket configured, no environment, a
  missing screenshots directory, or a provider error on one file all come
  back as an empty (or partial) list rather than an error tuple. The QA
  pass is the thing that must not be lost — "evidence not uploaded" is a
  note on the response, never a reason to refuse the attempt (criterion
  1847's local-dev case).
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths
  alias CodeMySpec.Uploads

  @extensions %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".webm" => "video/webm",
    ".mp4" => "video/mp4",
    ".mov" => "video/quicktime"
  }

  @doc """
  Collect and upload every file under `story_number`'s screenshot
  directory, keyed `qa/<project_id>/<attempt_id>/<filename>` — the same
  prefix-under-owner shape `IssueScreenshotController` already serves from.

  Returns a list of maps shaped like `CodeMySpec.Qa.Evidence`'s fields.
  Never raises and never returns an error — an empty list means nothing
  was uploaded, for whatever reason.
  """
  @spec collect(Environment.t() | nil, Ecto.UUID.t() | nil, Ecto.UUID.t(), integer() | String.t()) ::
          [map()]
  def collect(env, project_id, attempt_id, story_number)

  def collect(_env, nil, _attempt_id, _story_number), do: []
  def collect(nil, _project_id, _attempt_id, _story_number), do: []

  def collect(env, project_id, attempt_id, story_number) do
    if Uploads.configured?() do
      env
      |> Environments.list_directory(screenshot_dir(story_number))
      |> case do
        {:ok, names} -> names
        {:error, _reason} -> []
      end
      |> Enum.map(&upload_one(env, project_id, attempt_id, story_number, &1))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp upload_one(env, project_id, attempt_id, story_number, name) do
    path = Path.join(screenshot_dir(story_number), name)
    content_type = content_type(name)
    key = "qa/#{project_id}/#{attempt_id}/#{name}"

    with {:ok, bytes} <- Environments.read_file(env, path),
         {:ok, url} <- Uploads.presigned_upload_url(key, content_type),
         :ok <- Uploads.upload(url, bytes, content_type) do
      %{name: name, s3_key: key, content_type: content_type, bytes: byte_size(bytes)}
    else
      {:error, _reason} -> nil
    end
  end

  defp screenshot_dir(story_number),
    do: Path.join([Paths.qa_dir(), to_string(story_number), "screenshots"])

  defp content_type(name) do
    name
    |> Path.extname()
    |> String.downcase()
    |> then(&Map.get(@extensions, &1, "application/octet-stream"))
  end
end
