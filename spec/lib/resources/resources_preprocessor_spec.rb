require "spec_helper"

describe Resources::PreProcessor do
  DeliveryInfoShim = Struct.new(:routing_key)
  CHANNEL_TPL =
    "bot.device_%{device_id}.resources_v0.%{action}.%{klass}.%{id}.%{uuid}"

  let(:pb) { FactoryBot.create(:pin_binding) }

  let(:props) do
    { device_id: pb.device.id,
       action:   "destroy",
       klass:    pb.class,
       id:       pb.id,
       uuid:     SecureRandom.uuid }
  end

  let(:preprocessed) do
    body   = {}.to_json
    chan   = CHANNEL_TPL % props
    Resources::PreProcessor.from_amqp(DeliveryInfoShim.new(chan), body)
  end

  it "converts string types to real types" do
    expect(preprocessed[:action]).to      eq("destroy")
    expect(preprocessed[:device]).to      eq(pb.device)
    expect(preprocessed[:body]).to        eq({})
    expect(preprocessed[:resource]).to    eq(PinBinding)
    expect(preprocessed[:resource_id]).to eq(pb.id)
    expect(preprocessed[:uuid]).to        eq(props[:uuid])
  end

  it "handles bad JSON" do
    body   = "}{"
    chan   = CHANNEL_TPL % props
    expect do
      Resources::PreProcessor.from_amqp(DeliveryInfoShim.new(chan), body)
    end.to raise_error(Mutations::ValidationException, "body must be a JSON object")
  end

  describe Resources::Service do
    it "handles failure" do
      body   = "[]"
      chan   = CHANNEL_TPL % props
      result = Resources::Service.process(DeliveryInfoShim.new(chan), body)
      err    = result.calls[:publish].last
      expect(err).to be_kind_of(Array)
      expect(err.last).to be_kind_of(Hash)
      expect(err.last[:routing_key]).to be_kind_of(String)
      dev_id = err.last[:routing_key].split(".").second
      expect(dev_id).to eq("device_#{props[:device_id]}")
      body = JSON.parse(err.first).deep_symbolize_keys
      expect(body[:kind]).to eq("rpc_error")
      expect(body[:args]).to be_kind_of(Hash)
      expect(body[:body]).to be_kind_of(Array)
      expl = body[:body].first
      expect(expl).to be_kind_of(Hash)
      expect(expl[:kind]).to eq("explanation")
      expect(expl[:args][:message]).to eq("body must be a JSON object")
    end

    it "processes resources" do
      body   = {}.to_json
      chan   = CHANNEL_TPL % props
      before = PinBinding.count
      result = Resources::Service.process(DeliveryInfoShim.new(chan), body)
      # expect(result).to eq("")
      expect(PinBinding.count).to be < before
    end
  end

  describe Resources::Job do
    it "executes deletion" do
      y = preprocessed
      before = PinBinding.count
      x = Resources::Job.run(y)
      expect(x.success?).to be true
      expect(before).to     be > PinBinding.count
    end

    it "crashes when attempting to process unsupported classes" do
      y               = preprocessed
      y[:resource]    = Device
      y[:resource_id] = y[:device].id
      xpect           = "PANIC: Tried to do batch op on Device"
      expect { Resources::Job.run(y) }.to raise_error(xpect)
    end
  end
end
