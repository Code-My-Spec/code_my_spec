defmodule CodeMySpec.Users.UserNotifier do
  @moduledoc false
  import Swoosh.Email

  alias CodeMySpec.Mailer
  alias CodeMySpec.Users.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, text, html) do
    email =
      new()
      |> to(recipient)
      |> from({"CodeMySpec", "contact@codemyspec.com"})
      |> subject(subject)
      |> text_body(text)
      |> html_body(html)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    text = """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """

    html =
      cta_email_html(
        heading: "Confirm your email change",
        body: "You requested a change to your CodeMySpec login email. Click below to confirm.",
        cta_label: "Confirm email change",
        url: url,
        footer: "If you didn't request this change, ignore this email."
      )

    deliver(user.email, "Update email instructions", text, html)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    text = """

    ==============================

    Here's your login link:

    #{url}

    This link expires in 60 minutes.

    If you didn't request this, ignore this email.

    ==============================
    """

    html =
      cta_email_html(
        heading: "Sign in to CodeMySpec",
        body: "Click below to sign back in to your dashboard.",
        cta_label: "Sign in",
        url: url,
        footer: "Link expires in 60 minutes. If you didn't request this, ignore this email."
      )

    deliver(user.email, "Your CodeMySpec login link", text, html)
  end

  defp deliver_confirmation_instructions(user, url) do
    text = """

    ==============================

    Welcome to CodeMySpec.

    Click below to confirm your account and get started:

    #{url}

    Next: connect a Phoenix project from the dashboard, then install the
    Claude Code plugin to start writing specs.

    This link expires in 60 minutes.

    If you didn't sign up, ignore this email.

    -- John

    ==============================
    """

    html =
      cta_email_html(
        heading: "Welcome to CodeMySpec.",
        body:
          "Confirm your email to land on the dashboard. From there you'll connect a " <>
            "Phoenix project and install the Claude Code plugin.",
        cta_label: "Confirm email &amp; continue",
        url: url,
        footer: "Link expires in 60 minutes. If you didn't sign up, ignore this email."
      )

    deliver(user.email, "Your CodeMySpec login link", text, html)
  end

  # Minimal email-safe HTML — inline styles, table-free single column.
  # Renders the same primary CTA in every transactional email so the
  # button is the unambiguous action; the raw URL stays available as a
  # fallback for mail clients that strip the button.
  defp cta_email_html(opts) do
    heading = Keyword.fetch!(opts, :heading)
    body = Keyword.fetch!(opts, :body)
    cta_label = Keyword.fetch!(opts, :cta_label)
    url = Keyword.fetch!(opts, :url)
    footer = Keyword.fetch!(opts, :footer)

    """
    <!doctype html>
    <html><head><meta charset="utf-8"></head>
    <body style="margin:0;padding:0;background:#0a0a0a;color:#e6e6e6;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;">
      <div style="max-width:560px;margin:0 auto;padding:32px 24px;">
        <div style="font-size:11px;letter-spacing:0.22em;text-transform:uppercase;color:#ff3838;margin-bottom:18px;">// codemyspec</div>
        <h1 style="font-size:22px;font-weight:700;letter-spacing:-0.01em;margin:0 0 16px;color:#ffffff;">#{heading}</h1>
        <p style="font-size:14px;line-height:1.55;margin:0 0 24px;color:#cccccc;">#{body}</p>
        <a href="#{url}" style="display:inline-block;background:#ff3838;color:#ffffff;text-decoration:none;font-weight:700;font-size:13px;letter-spacing:0.12em;text-transform:uppercase;padding:14px 22px;border-radius:2px;">#{cta_label}</a>
        <p style="font-size:12px;line-height:1.5;margin:28px 0 0;color:#888888;word-break:break-all;">If the button doesn't work, paste this URL into your browser:<br><span style="color:#aaaaaa;">#{url}</span></p>
        <p style="font-size:11px;line-height:1.5;margin:24px 0 0;color:#666666;">#{footer}</p>
      </div>
    </body></html>
    """
  end
end
