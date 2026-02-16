defmodule Membrane.Gemini.Integration.ErrorHandlingTest do
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec

  @input_audio_format %Membrane.RawAudio{
    channels: 1,
    sample_rate: 16_000,
    sample_format: :s16le
  }

  defp pipeline_spec() do
    [
      child(:audio_source, %Membrane.Testing.Source{
        stream_format: @input_audio_format,
        output: []
      })
      |> via_in(:in_audio)
      |> child(:gemini, %Membrane.Gemini.Bin{mode: :discrete})
      |> child(:sink, Membrane.Testing.Sink),
      child(:text_source, %Membrane.Testing.Source{output: ["Hello"]})
      |> via_in(:in_text)
      |> get_child(:gemini)
    ]
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

    test "pipeline fails when API key is missing" do
      System.delete_env("GEMINI_API_KEY")

      {:ok, supervisor, pipeline} =
        Membrane.Testing.Pipeline.start(spec: pipeline_spec())

      pipeline_ref = Process.monitor(pipeline)
      supervisor_ref = Process.monitor(supervisor)

      assert_receive {:DOWN, ^pipeline_ref, :process, ^pipeline, _reason},
                     5_000,
                     "Pipeline should crash when API key is missing"

      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _reason}
    end

    test "pipeline fails when API key is invalid" do
      System.put_env("GEMINI_API_KEY", "invalid_key_12345")

      {:ok, supervisor, pipeline} =
        Membrane.Testing.Pipeline.start(spec: pipeline_spec())

      supervisor_ref = Process.monitor(supervisor)
      pipeline_ref = Process.monitor(pipeline)

      assert_receive {:DOWN, ^pipeline_ref, :process, ^pipeline,
                      {:membrane_child_crash, :gemini,
                       {:membrane_child_crash, :gemini, {%RuntimeError{}, _stacktrace}}}},
                     5_000,
                     "Pipeline should crash when API key is invalid"

      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _reason}
    end
  end
end
