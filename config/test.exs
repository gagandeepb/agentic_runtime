import Config

config :agentic_runtime, AgenticRuntime.TestRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "agentic_runtime_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :agentic_runtime,
  ecto_repos: [AgenticRuntime.TestRepo],
  repo: AgenticRuntime.TestRepo,
  pubsub_name: AgenticRuntime.TestPubSub,
  presence_module: AgenticRuntime.TestPresence,
  server_adapter: AgenticRuntime.Agents.ServerAdapter.Mock,
  supervisor_adapter: AgenticRuntime.Agents.SupervisorAdapter.Mock

config :logger, level: :warning
