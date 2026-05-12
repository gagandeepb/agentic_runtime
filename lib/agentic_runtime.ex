defmodule AgenticRuntime do
  @moduledoc """
  Public API for the AgenticRuntime library — an opinionated agent and
  conversation runtime layered on top of `Sagents` and `LangChain` for
  Phoenix applications.

  See the README for a getting-started guide and configuration reference.
  """

  alias AgenticRuntime.Agents.Factory
  alias AgenticRuntime.Agents.ServerAdapter
  alias AgenticRuntime.Agents.SupervisorAdapter

  defdelegate build_anthropic_model_config(model_name, api_key, opts \\ []), to: Factory
  defdelegate build_openai_model_config(model_name, api_key), to: Factory
  defdelegate build_googleai_model_config(model_name, api_key), to: Factory

  @doc """
  Build a fully-configured `Sagents.Agent` struct.

  Required opts:
    * `:agent_id`
    * `:model_config`
    * `:base_system_prompt`

  See `AgenticRuntime.Agents.Factory.create_agent/1` for the full set of options.
  """
  defdelegate create_agent(opts), to: Factory

  defdelegate build_new_user_message!(message_text), to: LangChain.Message, as: :new_user!

  def add_message(agent_id, langchain_message),
    do: ServerAdapter.impl().add_message(agent_id, langchain_message)

  def cancel_agent_execution(agent_id), do: ServerAdapter.impl().cancel(agent_id)

  defdelegate new_tool!(function_schema), to: LangChain.Function, as: :new!

  def start_runtime(opts), do: SupervisorAdapter.impl().child_spec(opts)
end
