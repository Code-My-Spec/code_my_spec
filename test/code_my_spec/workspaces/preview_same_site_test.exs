defmodule CodeMySpec.Workspaces.PreviewSameSiteTest do
  @moduledoc """
  A preview has to be same-site with the page framing it, or the framed app
  cannot hold a session.

  Story 886's criterion 2327 used to assert this by driving the proxy in
  process. The proxy is gone — a tunnel cannot be exercised in a test — so the
  criterion lost its coverage, and it is the one that had already cost an
  afternoon: Broken Oaths' login page looped forever in the pane because dev
  previews sat on `astralbi.com` while the app framing them was on
  `codemyspec.com`.

  ## Why this is checkable without a browser

  The failure is not subtle at runtime, it is just silent. Every generated
  Phoenix app sets `SameSite=Lax`, and no browser sends a Lax cookie into a
  cross-site frame. So the app is session-less on every request: its login page
  renders, sets a cookie that never comes back, and redirects to itself. Nothing
  errors, and it reads as the framed app being broken.

  But whether it *will* happen is decided entirely by configuration — the
  preview's domain and the embedder's — and that can be compared here, at the
  cost of no network and no browser. This test is the one that would have caught
  it in the morning rather than the afternoon.

  ## Registrable domain, approximately

  Last two labels, which is right for every domain this project uses and wrong
  in general — `foo.co.uk` needs the Public Suffix List. Stated rather than
  hidden: if previews ever move under a multi-part suffix, this comparison gets
  the answer wrong in the permissive direction, which is the bad one.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Workspaces.{PreviewAddress, PreviewTunnel}

  test "every origin allowed to frame a preview is same-site with it" do
    preview = PreviewAddress.host("11111111-1111-4111-8111-111111111111")
    preview_site = registrable(preview)

    cross_site =
      PreviewTunnel.embedder()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(registrable_of_origin(&1) == preview_site))

    assert cross_site == [],
           """
           These origins may frame a preview but are not same-site with it:

               #{Enum.join(cross_site, "\n    ")}

           The preview is #{preview} (site: #{preview_site}).

           A generated app sets SameSite=Lax, and no browser sends a Lax cookie \
           into a cross-site frame. The frame will render and the app inside it \
           will be session-less on every request — its login page renders, sets \
           a cookie that never comes back, and redirects to itself forever. \
           Nothing errors, so it reads as the framed app being broken.

           Either move the preview domain under the same registrable domain as \
           the embedder, or stop allowing that origin to frame it. Allowing an \
           origin that cannot hold a session is worse than refusing it: refusing \
           shows an empty pane, allowing shows a login loop.
           """
  end

  defp registrable_of_origin(origin) do
    origin |> URI.parse() |> Map.get(:host) |> to_string() |> registrable()
  end

  defp registrable(host) do
    host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end
end
