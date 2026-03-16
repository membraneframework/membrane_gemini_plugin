defmodule Membrane.Gemini.Integration.ErrorHandlingTest do
  # These tests exercise the mock server's API key validation.
  # The mock server only accepts GEMINI_API_KEY="mock-api-key".
  use Membrane.Gemini.Case

  import Membrane.ChildrenSpec

  @input_audio_format %Membrane.RawAudio{
    channels: 1,
    sample_rate: 16_000,
    sample_format: :s16le
  }

  @spec pipeline_spec(extra_opts :: Keyword.t()) :: [Membrane.ChildrenSpec.builder()]
  defp pipeline_spec(extra_opts) do
    [
      child(:audio_source, %Membrane.Testing.Source{
        stream_format: @input_audio_format,
        output: []
      })
      |> via_in(:audio_input)
      |> child(:gemini, %Membrane.Gemini.Bin{
        mode: :discrete,
        extra_opts: extra_opts
      })
      |> child(:sink, Membrane.Testing.Sink),
      child(:text_source, %Membrane.Testing.Source{output: ["Hello"]})
      |> via_in(:text_input)
      |> get_child(:gemini)
    ]
  end

  @spec run_pipeline_assert_crash(extra_opts :: Keyword.t()) :: any()
  defp run_pipeline_assert_crash(extra_opts) do
    {:ok, supervisor, pipeline} =
      Membrane.Testing.Pipeline.start(spec: pipeline_spec(extra_opts))

    pipeline_ref = Process.monitor(pipeline)
    supervisor_ref = Process.monitor(supervisor)

    assert_receive {:DOWN, ^pipeline_ref, :process, ^pipeline,
                    {:membrane_child_crash, _child,
                     {:membrane_child_crash, _inner_child, {%RuntimeError{}, _stacktrace}}}},
                   6_000,
                   "Pipeline should crash when API key is invalid"

    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor,
                    {:membrane_child_crash, _child,
                     {:membrane_child_crash, _inner_child, {%RuntimeError{}, _stacktrace}}}}
  end

  describe "API key validation" do
    setup do
      original_key = System.get_env("GEMINI_API_KEY")

      # Other tests break unless the proper API key is restored
      on_exit(fn ->
        if is_nil(original_key) do
          System.delete_env("GEMINI_API_KEY")
        else
          System.put_env("GEMINI_API_KEY", original_key)
        end
      end)

      :ok
    end

    test "pipeline fails when API key is missing", %{extra_opts: extra_opts} = _ctx do
      System.delete_env("GEMINI_API_KEY")
      run_pipeline_assert_crash(extra_opts)
    end

    test "pipeline fails when API key is invalid", %{extra_opts: extra_opts} = _ctx do
      System.put_env("GEMINI_API_KEY", "invalid_key_12345")
      run_pipeline_assert_crash(extra_opts)
    end
  end
end
