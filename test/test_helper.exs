{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ex_machina)

{:ok, _} = AgenticRuntime.TestRepo.start_link()
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: AgenticRuntime.TestPubSub)
{:ok, _} = AgenticRuntime.TestPresence.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AgenticRuntime.TestRepo, :manual)

Mox.defmock(AgenticRuntime.Agents.ServerAdapter.Mock,
  for: AgenticRuntime.Agents.ServerAdapter
)

Mox.defmock(AgenticRuntime.Agents.SupervisorAdapter.Mock,
  for: AgenticRuntime.Agents.SupervisorAdapter
)

Application.put_env(:agentic_runtime, :server_adapter, AgenticRuntime.Agents.ServerAdapter.Mock)

Application.put_env(
  :agentic_runtime,
  :supervisor_adapter,
  AgenticRuntime.Agents.SupervisorAdapter.Mock
)

ExUnit.start(exclude: [:integration])
