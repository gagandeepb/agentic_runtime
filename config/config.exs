import Config

if config_env() != :prod do
  import_config "#{config_env()}.exs"
end
