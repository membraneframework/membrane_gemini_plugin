import Config

if config_env() == :test do
  config :membrane_gemini_plugin, real_api_key: System.get_env("MEMBRANE_TEST_GEMINI_API_KEY")
end
