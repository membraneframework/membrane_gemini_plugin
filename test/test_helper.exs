IO.puts("""
To run tests against a real Gemini Live API server,
set `MEMBRANE_TEST_GEMINI_API_KEY` and include tests with the `:real` tag:
`MEMBRANE_TEST_GEMINI_API_KEY=<your api key> mix test --include real`
""")

ExUnit.start(
  capture_log: true,
  exclude: [:real]
)
