class WavWriter
    attr_reader :sample_rate, :channels, :bits_per_sample, :data_bytes
  
    def initialize(path, sample_rate, channels, bits_per_sample)
      @f = File.open(path, "wb")
      @sample_rate = sample_rate
      @channels = channels
      @bits_per_sample = bits_per_sample
      @data_bytes = 0
  
      write_header_placeholder
    end
  
    def write_s16(samples)
      # samples は int16 の配列（フレーム数 × チャンネル数）
      bin = samples.pack("s<" * samples.size)
      @f.write(bin)
      @data_bytes += bin.bytesize
      0
    end
  
    def close
      riff_size = 4 + (8 + 16) + (8 + @data_bytes)
  
      # RIFF chunk size
      @f.seek(4)
      @f.write([riff_size].pack("V"))
  
      # data chunk size
      @f.seek(40)
      @f.write([@data_bytes].pack("V"))
  
      @f.close
      0
    end
  
    private
  
    def write_header_placeholder
      # RIFF header
      @f.write("RIFF")
      @f.write([0].pack("V"))  # placeholder
      @f.write("WAVE")
  
      # fmt chunk
      @f.write("fmt ")
      @f.write([16].pack("V"))        # chunk size
      @f.write([1].pack("v"))         # PCM
      @f.write([@channels].pack("v"))
      @f.write([@sample_rate].pack("V"))
  
      byte_rate = @sample_rate * @channels * (@bits_per_sample / 8)
      @f.write([byte_rate].pack("V"))
  
      block_align = @channels * (@bits_per_sample / 8)
      @f.write([block_align].pack("v"))
      @f.write([@bits_per_sample].pack("v"))
  
      # data chunk
      @f.write("data")
      @f.write([0].pack("V"))  # placeholder
    end
  end
  