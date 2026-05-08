defmodule AgenticRuntime.Agents.ServerAdapter do
  @moduledoc """
  Behaviour wrapping the subset of `Sagents.AgentServer` that AgenticRuntime
  calls into. Configurable via `:server_adapter` so tests can swap a Mox.

      config :agentic_runtime, server_adapter: AgenticRuntime.Agents.ServerAdapter.Mock
  """

  @callback add_message(String.t(), LangChain.Message.t()) :: :ok | {:error, term()}
  @callback cancel(String.t()) :: :ok | {:error, term()}
  @callback get_pid(String.t()) :: pid() | nil
  @callback stop(String.t()) :: :ok
  @callback get_status(String.t()) :: atom()
  @callback get_info(String.t()) :: map()
  @callback resume(String.t(), term()) :: :ok | {:error, term()}

  def impl, do: Application.get_env(:agentic_runtime, :server_adapter, __MODULE__.Sagents)
end

defmodule AgenticRuntime.Agents.ServerAdapter.Sagents do
  @behaviour AgenticRuntime.Agents.ServerAdapter

  defdelegate add_message(agent_id, message), to: Sagents.AgentServer
  defdelegate cancel(agent_id), to: Sagents.AgentServer
  defdelegate get_pid(agent_id), to: Sagents.AgentServer
  defdelegate stop(agent_id), to: Sagents.AgentServer
  defdelegate get_status(agent_id), to: Sagents.AgentServer
  defdelegate get_info(agent_id), to: Sagents.AgentServer
  defdelegate resume(agent_id, resume_data), to: Sagents.AgentServer
end
