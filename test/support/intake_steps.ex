defmodule CodeMySpecSpex.IntakeSteps do
  @moduledoc """
  Driving the guided intake the way a visitor does.

  The shaping step is a conversation, so a spec that needs a visitor past it
  answers in sentences, not in fields. Specs used to post three form values in
  one go, which is how a page of dropdowns survived a rule that never
  sanctioned it — every spec agreed with the implementation because each was
  written against it.

  How many questions get asked is the shaper's business, not the spec's, so
  this answers whatever is on screen until the conversation ends.

  Import where a spec needs a plan that has got past the questions:

      import CodeMySpecSpex.IntakeSteps

      view |> describe_idea("a booking tool for hair salons") |> answer_shaping_questions()
  """

  import Phoenix.LiveViewTest

  alias Plug.Conn

  @default_answers ["salon owners see their week, and their clients book themselves in"]

  @doc "Submits the opening description and returns the view."
  def describe_idea(view, description) do
    view
    |> form("form[phx-submit=describe]", %{description: description})
    |> render_submit()

    view
  end

  @doc """
  Confirms the plan the way the visitor does, and follows where it sends them.

  There is no separate "where should it run" step to drive any more — the
  choice is a field on the confirmation card, so confirming *is* choosing. A
  spec that still submits `choose_location` is describing a page that no longer
  exists.

  Returns the path the confirmation navigated to, so a spec can assert on where
  the visitor ended up rather than assuming it.
  """
  def confirm_plan(view, attrs \\ %{location: "cloud"}) do
    view
    |> form("form[phx-submit=confirm_names]", %{plan: attrs})
    |> render_submit()
    |> case do
      {:error, {:live_redirect, %{to: to}}} -> to
      {:error, {:redirect, %{to: to}}} -> to
      _html -> nil
    end
  end

  @doc """
  Answers each shaping question in turn until none is left.

  Bounded by the number of answers given rather than looping until the form
  disappears, so a spec fails on its own assertion rather than hanging if the
  conversation stops advancing.
  """
  def answer_shaping_questions(view, answers \\ @default_answers) do
    Enum.reduce(answers, render(view), fn answer, html ->
      if has_element?(view, "form[phx-submit=answer]") do
        view |> form("form[phx-submit=answer]", %{answer: answer}) |> render_submit()
      else
        html
      end
    end)
  end

  @doc """
  Stubs Stripe to accept a subscription the way local's 7-day trial does — a
  `trialing` subscription with a `pending_setup_intent` rather than an
  invoice, since a trial has nothing due today (990/3400 follow-up: local is
  its own $25/month tier now, not a free path, so any spec that reaches
  `/build/workspace` with `location: "local"` goes through this same gate
  cloud already did). `secret_key`, the price ids and `webhook_secret` are the
  ones config/test.exs already sets globally, statically — only the Req
  plug's response is test-specific here.
  """
  def stub_local_trial do
    Req.Test.stub(CodeMySpec.Billing.StripeClient, fn
      %{request_path: "/v1/customers"} = conn ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(200, Jason.encode!(%{"id" => "cus_intake_steps"}))

      %{request_path: "/v1/subscriptions"} = conn ->
        body = %{
          "id" => "sub_intake_steps",
          "status" => "trialing",
          "latest_invoice" => nil,
          "pending_setup_intent" => %{"client_secret" => "seti_1_secret"}
        }

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  @doc "Confirms the trial's card, the way the browser's Stripe hook would."
  def confirm_payment(view), do: render_hook(view, "payment_confirmed", %{})
end
