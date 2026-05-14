defmodule AgenticRuntime.Agents.SupervisorAdapter do
  @moduledoc """
  Behaviour wrapping the subset of `Sagents.AgentsDynamicSupervisor` and
  `Sagents.Supervisor` that AgenticRuntime calls into. Configurable via
  `:supervisor_adapter` so tests can swap a Mox without spawning real agents.

      config :agentic_runtime, supervisor_adapter: AgenticRuntime.Agents.SupervisorAdapter.Mock
  """

  @callback start_agent_sync(keyword()) ::
              {:ok, pid()} | {:ok, pid(), :already_started} | {:error, term()}
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  def start_agent_sync(opts), do: impl().start_agent_sync(opts)
  def start_runtime(opts), do: impl().child_spec(opts)

  defp impl, do: Application.get_env(:agentic_runtime, :supervisor_adapter, __MODULE__.Sagents)
end

defmodule AgenticRuntime.Agents.SupervisorAdapter.Sagents do
  @behaviour AgenticRuntime.Agents.SupervisorAdapter

  defdelegate start_agent_sync(opts), to: Sagents.AgentsDynamicSupervisor
  defdelegate child_spec(opts), to: Sagents.Supervisor
end
