defmodule Membrane.Gemini.Integration.Test do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  @input_audio_format %Membrane.RawAudio{
    channels: 1,
    sample_rate: 16_000,
    sample_format: :s16le
  }

  defp test_setup(:mock) do
    Application.put_env(:gemini_ex, :api_key, "mock-api-key")
    {:ok, extra_opts: [websocket_module: Membrane.Gemini.MockWebSocket]}
  end

  defp test_setup(:real) do
    Application.put_env(
      :gemini_ex,
      :api_key,
      Application.get_env(:membrane_gemini_plugin, :real_api_key)
    )

    {:ok, extra_opts: []}
  end

  defp run_pipeline_assert_crash(extra_opts, message) do
    spec = [
      child(:audio_source, %Membrane.Testing.Source{
        stream_format: @input_audio_format,
        output: []
      })
      |> via_in(:audio_input)
      |> child(:gemini, %Membrane.Gemini.Bin{
        model: "gemini-2.5-flash-native-audio-latest",
        mode: :paced,
        extra_opts: extra_opts
      })
      |> child(:sink, Membrane.Testing.Sink),
      child(:text_source, %Membrane.Testing.Source{output: ["Hello"]})
      |> via_in(:text_input)
      |> get_child(:gemini)
    ]

    {:ok, supervisor, pipeline} =
      Membrane.Testing.Pipeline.start(spec: spec)

    pipeline_ref = Process.monitor(pipeline)
    supervisor_ref = Process.monitor(supervisor)

    expected_error = %RuntimeError{message: message}

    assert_receive {:DOWN, ^pipeline_ref, :process, ^pipeline,
                    {:membrane_child_crash, _child,
                     {:membrane_child_crash, _inner_child, {^expected_error, _stacktrace}}}},
                   6_000,
                   "Pipeline should crash when API key is invalid"

    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor,
                    {:membrane_child_crash, _child,
                     {:membrane_child_crash, _inner_child, {^expected_error, _stacktrace}}}}
  end

  for test_type <- [:mock, :real] do
    describe "using #{test_type} server," do
      setup do
        test_setup(unquote(test_type))
      end

      @tag test_type
      test "Gemini responds to a simple text prompt", %{extra_opts: extra_opts} do
        spec = [
          child(:audio_source, %Membrane.Testing.Source{
            stream_format: @input_audio_format,
            output: []
          })
          |> via_in(:audio_input)
          |> child(:gemini, %Membrane.Gemini.Bin{mode: :raw, extra_opts: extra_opts})
          |> child(:sink, Membrane.Testing.Sink),
          child(:text_source, %Membrane.Testing.Source{
            output: ["Hello, world!"]
          })
          |> via_in(:text_input)
          |> get_child(:gemini)
        ]

        {:ok, _supervisor_pid, pipeline_pid} = Membrane.Testing.Pipeline.start(spec: spec)

        timeout_ms = 5_000

        assert_sink_event(
          pipeline_pid,
          :sink,
          %Membrane.Gemini.Events.ResponseStart{},
          timeout_ms
        )

        assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.Events.Thinking{}, timeout_ms)

        assert_sink_event(
          pipeline_pid,
          :sink,
          %Membrane.Gemini.Events.Transcript{audio_origin: :server},
          timeout_ms
        )

        assert_sink_buffer(pipeline_pid, :sink, %Membrane.Buffer{}, timeout_ms)
        assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.Events.ResponseEnd{}, timeout_ms)
        assert_end_of_stream(pipeline_pid, :sink, :input, timeout_ms)
      end

      @tag test_type
      test "pipeline fails when API key is missing", %{extra_opts: extra_opts} do
        Application.delete_env(:gemini_ex, :api_key)

        run_pipeline_assert_crash(
          extra_opts,
          "Failed to start Gemini Live API session, error: {:setup_failed, {:closed, 1008, \"Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API c\"}}"
        )
      end

      @tag test_type
      test "pipeline fails when API key is invalid", %{extra_opts: extra_opts} do
        Application.put_env(:gemini_ex, :api_key, "invalid-key")

        run_pipeline_assert_crash(
          extra_opts,
          "Failed to start Gemini Live API session, error: {:setup_failed, {:closed, 1007, \"API key not valid. Please pass a valid API key.\"}}"
        )
      end
    end
  end

  # To regenerate fixture:
  # $ espeak-ng -v en-gb-scotland "Hello, world!" -w hello.wav
  # $ ffmpeg -i hello.wav -ar 16000 -f s16le -acodec pcm_s16le test/fixtures/hello.raw
  @hello_raw_audio "./test/fixtures/hello.raw"

  @tag :real
  test "Gemini responds to a simple audio prompt" do
    # NOTE: `Membrane.Gemini.Bin` is aware that it sent a text prompt,
    # NOTE: but not an audio prompt, since it relies on the Live API server's
    # NOTE: VAD to detect if the user is speaking.
    # NOTE: This means an EOS can only be prevented from being sent
    # NOTE: and terminating the pipeline after the response starts being received.
    # NOTE: To avoid premature termination, we use a realtimer to enforce
    # NOTE: a steady stream from the testing source and pad the rest of the audio
    # NOTE: with silence for the VAD to kick in.
    Application.put_env(
      :gemini_ex,
      :api_key,
      Application.get_env(:membrane_gemini_plugin, :real_api_key)
    )

    silence_1s =
      Membrane.RawAudio.silence(@input_audio_format, Membrane.Time.second())

    test_buffers =
      [
        File.read!(@hello_raw_audio)
        | List.duplicate(silence_1s, 10)
      ]
      |> Enum.map(&%Membrane.Buffer{payload: &1})

    spec = [
      child(:audio_source, %Membrane.Testing.Source{
        stream_format: @input_audio_format,
        output: test_buffers
      })
      |> child(:parser, %Membrane.RawAudioParser{
        overwrite_pts?: true
      })
      |> child(:realtimer, Membrane.Realtimer)
      |> via_in(:audio_input)
      |> child(:gemini, %Membrane.Gemini.Bin{
        mode: :raw,
        # NOTE: The VAD used by Gemini 3.1 doesn't detect
        # NOTE: TTS voice activity, hence we need to use 2.5 here
        model: "gemini-2.5-flash-native-audio-latest"
      })
      |> child(:sink, Membrane.Testing.Sink),
      child(:text_source, %Membrane.Testing.Source{output: []})
      |> via_in(:text_input)
      |> get_child(:gemini)
    ]

    {:ok, _supervisor_pid, pipeline_pid} = Membrane.Testing.Pipeline.start(spec: spec)

    timeout_ms = 15_000

    assert_sink_event(
      pipeline_pid,
      :sink,
      %Membrane.Gemini.Events.Transcript{audio_origin: :client},
      timeout_ms
    )

    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.Events.ResponseStart{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.Events.Thinking{}, timeout_ms)

    assert_sink_event(
      pipeline_pid,
      :sink,
      %Membrane.Gemini.Events.Transcript{audio_origin: :server},
      timeout_ms
    )

    assert_sink_buffer(pipeline_pid, :sink, %Membrane.Buffer{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.Events.ResponseEnd{}, timeout_ms)
    assert_end_of_stream(pipeline_pid, :sink, :input, timeout_ms)
  end
end
