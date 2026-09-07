SDSP_SAMPLE_RATE = 32000
CPU_CYCLES_PER_SAMPLE = 32
class SpcEngine
    attr_accessor :dsp, :cpu, :loaded, :cycle_accum
  
    def initialize(dsp: nil, cpu: nil, loaded: 0, cycle_accum: 0)
      @dsp = dsp
      @cpu = cpu
      @loaded = loaded
      @cycle_accum = cycle_accum
    end
end
def engine_load(eng,parsed)
    dsp_init(eng.dsp, eng.cpu.ram)
    spc700_init(eng.cpu, eng.dsp)
end
def engine_render_sample(eng,outL,outR) 
    
end