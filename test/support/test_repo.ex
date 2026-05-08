defmodule AgenticRuntime.TestRepo do
  use Ecto.Repo,
    otp_app: :agentic_runtime,
    adapter: Ecto.Adapters.Postgres
end
