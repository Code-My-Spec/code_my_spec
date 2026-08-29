defmodule CodeMySpec.Research.Fetch.GitHub do
  @moduledoc """
  GitHub file views, read as files. Adapted from Omni Tools (Apache-2.0).

  A `/blob/` URL serves an application: the file arrives split across DOM nodes
  with line numbers, inside a page of navigation, and lately not in the initial
  HTML at all. `raw.githubusercontent.com` serves the same bytes plain, so the
  rewrite is the difference between reading the source and reading a shell.
  """

  @behaviour CodeMySpec.Research.Fetch.Strategy

  alias CodeMySpec.Research.Fetch.Default

  @hosts ~w(github.com www.github.com)

  @impl true
  def matches?(%URI{host: host, path: path}) when is_binary(path),
    do: host in @hosts and String.contains?(path, "/blob/")

  def matches?(_uri), do: false

  @impl true
  def prepare(url, %URI{path: path} = uri) do
    raw = String.replace(path, "/blob/", "/", global: false)

    # The line anchor is the reason someone had this URL, but it means nothing
    # to a raw file and would be sent as part of nothing.
    %{uri | host: "raw.githubusercontent.com", path: raw, fragment: nil}
    |> URI.to_string()
    |> case do
      "" -> url
      rewritten -> rewritten
    end
  end

  @impl true
  defdelegate extract(response, requested, fetched), to: Default
end
