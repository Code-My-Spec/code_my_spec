defmodule CodeMySpec.Mailer do
  use Boundary, top_level?: true, deps: []

  use Swoosh.Mailer, otp_app: :code_my_spec
end
